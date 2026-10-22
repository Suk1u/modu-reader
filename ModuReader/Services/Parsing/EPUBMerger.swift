//
//  EPUBMerger.swift
//  ModuReader
//
//  把 EPUB 的所有 spine 资源合并成**单个 XHTML**，生成新的 EPUB。
//
//  ── 为什么需要合并 ──
//
//  Readium 的滚动模式是**按资源**的：每个 readingOrder 条目一个 WKWebView，
//  滚动到章末会停住，必须手势翻页才能进入下一章。
//  Apple Books 之所以能无缝滚动，是因为它把全书渲染在同一个文档流里。
//
//  合并后 readingOrder 只有一个条目，整本书是一条连续的内容流，
//  滚动自然从头贯穿到尾。
//
//  ── 合并时保留什么 ──
//
//  - 每个原章节的 <body> 内容，按顺序拼接
//  - 原章节引用的样式表（<link rel="stylesheet">）
//  - 所有图片、字体等资源文件（原样复制，路径不变）
//  - 目录：重新生成，指向 merged.xhtml#chN 锚点
//
//  只改写 HTML 里的相对路径（src/href），使它们相对合并后的文件位置仍然正确。
//

import Foundation

enum EPUBMerger {

    /// 合并后的文件名（放在 OPF 同目录）。
    static let mergedFileName = "merged.xhtml"

    /// 生成合并版 EPUB。
    ///
    /// - Parameters:
    ///   - source: 原始 .epub。
    ///   - output: 输出的合并版 .epub。
    static func buildMerged(from source: URL, to output: URL) throws {
        let archive = try ZipArchive(url: source)
        let entries = try archive.entries()

        // 1. 读 container.xml 找 OPF
        guard let containerEntry = entries.first(where: { $0.path == "META-INF/container.xml" }),
              let containerData = try? archive.data(for: containerEntry),
              let opfPath = try? EPUBParser.parseContainerPath(xml: containerData) else {
            throw EPUBMergeError.invalidEPUB
        }
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        guard let opfEntry = entries.first(where: { $0.path == opfPath }),
              let opfData = try? archive.data(for: opfEntry) else {
            throw EPUBMergeError.invalidEPUB
        }
        let package = try EPUBParser.parsePackageDocument(xml: opfData)

        // 2. 按 spine 顺序读取各章节 XHTML
        var sections: [String] = []
        var stylesheetHrefs: [String] = []
        var chapterTitles: [String] = []
        var chapterAnchors: [String] = []

        for (index, itemRef) in package.spine.enumerated() {
            guard let item = package.manifest[itemRef.idref] else { continue }
            let chapterPath = opfDirectory.isEmpty
                ? item.href
                : "\(opfDirectory)/\(item.href)"
            guard let entry = entries.first(where: { $0.path == chapterPath }),
                  let data = try? archive.data(for: entry),
                  let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf8) else {
                continue
            }

            let chapterDirectory = (chapterPath as NSString).deletingLastPathComponent
            let body = extractBody(from: html)
            let rewritten = rewriteReferences(
                in: body,
                fromDirectory: chapterDirectory,
                toDirectory: opfDirectory
            )

            // 收集该章的样式表（去重）
            for href in stylesheetHrefsIn(html) {
                let absoluteInZip = resolve(href, relativeTo: chapterDirectory)
                let relative = relativePath(from: opfDirectory, to: absoluteInZip)
                if !stylesheetHrefs.contains(relative) {
                    stylesheetHrefs.append(relative)
                }
            }

            let anchor = "ch\(index)"
            chapterAnchors.append(anchor)
            chapterTitles.append(itemRef.idref)
            sections.append("<section id=\"\(anchor)\">\n\(rewritten)\n</section>")
        }

        guard !sections.isEmpty else {
            throw EPUBMergeError.noContent
        }

        // 3. 生成合并后的 XHTML
        let mergedXHTML = makeMergedXHTML(
            sections: sections,
            stylesheets: stylesheetHrefs
        )

        // 4. 生成 nav.xhtml
        let navXHTML = makeNavXHTML(
            anchors: chapterAnchors,
            titles: chapterTitles,
            package: package
        )

        // 5. 生成新的 content.opf
        let newOPF = makePackageDocument(
            original: package,
            mergedFileName: mergedFileName
        )

        // 6. 打包：复制原资源，替换 OPF / container / mimetype，追加 merged 与 nav
        var newEntries: [SimpleZipWriter.Entry] = [
            .init(path: "mimetype", data: Data("application/epub+zip".utf8)),
            .init(path: "META-INF/container.xml", data: Data(containerXML(opfPath: "\(opfDirectory)/content.opf").utf8)),
            .init(path: "\(opfDirectory)/\(mergedFileName)".replacingOccurrences(of: "//", with: "/"),
                  data: Data(mergedXHTML.utf8)),
            .init(path: "\(opfDirectory)/nav.xhtml".replacingOccurrences(of: "//", with: "/"),
                  data: Data(navXHTML.utf8)),
            .init(path: "\(opfDirectory)/content.opf".replacingOccurrences(of: "//", with: "/"),
                  data: Data(newOPF.utf8)),
        ]

        for entry in entries {
            // 跳过会被替换的文件
            if entry.path == "mimetype"
                || entry.path == "META-INF/container.xml"
                || entry.path == opfPath
                || entry.path == "\(opfDirectory)/nav.xhtml"
                || entry.path == "\(opfDirectory)/\(mergedFileName)" {
                continue
            }
            guard let data = try? archive.data(for: entry) else { continue }
            newEntries.append(.init(path: entry.path, data: data))
        }

        try SimpleZipWriter.write(entries: newEntries, to: output)
        Diagnostics.log("EPUBMerger: 合并 \(sections.count) 章 → \(output.lastPathComponent)")
    }

    // MARK: - HTML 处理

    /// 取出 `<body>` 内部内容。
    private static func extractBody(from html: String) -> String {
        guard let open = html.range(of: "<body", options: .caseInsensitive) else {
            return html
        }
        guard let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) else {
            return html
        }
        let contentStart = openEnd.upperBound

        guard let close = html.range(of: "</body>", options: .caseInsensitive, range: contentStart..<html.endIndex) else {
            return String(html[contentStart...])
        }
        return String(html[contentStart..<close.lowerBound])
    }

    /// 收集 `<link rel="stylesheet" href="...">` 的 href。
    private static func stylesheetHrefsIn(_ html: String) -> [String] {
        let pattern = "<link[^>]*rel\\s*=\\s*[\"']stylesheet[\"'][^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>"
        let altPattern = "<link[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*rel\\s*=\\s*[\"']stylesheet[\"'][^>]*>"

        var results: [String] = []
        for pattern in [pattern, altPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges >= 2 else { continue }
                results.append(ns.substring(with: match.range(at: 1)))
            }
        }
        return results
    }

    /// 把 HTML 里的相对引用改写为相对合并文件位置的路径。
    private static func rewriteReferences(
        in html: String,
        fromDirectory: String,
        toDirectory: String
    ) -> String {
        let pattern = "(src|href)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let result = NSMutableString(string: html)

        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let attribute = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))

            // 跳过外链与锚点
            let lower = value.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || lower.hasPrefix("data:") || lower.hasPrefix("mailto:")
                || lower.hasPrefix("#") || lower.hasPrefix("//") {
                continue
            }

            // 分离 fragment
            var path = value
            var fragment = ""
            if let hash = path.firstIndex(of: "#") {
                fragment = String(path[hash...])
                path = String(path[..<hash])
            }
            guard !path.isEmpty else { continue }

            let absoluteInZip = resolve(path, relativeTo: fromDirectory)
            let rewritten = relativePath(from: toDirectory, to: absoluteInZip) + fragment
            result.replaceCharacters(
                in: match.range,
                with: "\(attribute)=\"\(rewritten)\""
            )
        }

        return result as String
    }

    // MARK: - 路径工具

    /// `path` 相对 `directory` 解析为 ZIP 内绝对路径（无前导斜杠）。
    static func resolve(_ path: String, relativeTo directory: String) -> String {
        let combined = directory.isEmpty ? path : "\(directory)/\(path)"
        return normalize(combined)
    }

    /// 规范化路径：处理 `./`、`../`、重复斜杠。
    static func normalize(_ path: String) -> String {
        var output: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !output.isEmpty { output.removeLast() }
            default:
                output.append(String(component))
            }
        }
        return output.joined(separator: "/")
    }

    /// 从 `from` 目录到 `to` 文件的相对路径。
    static func relativePath(from directory: String, to path: String) -> String {
        let fromParts = directory.split(separator: "/").map(String.init)
        let toParts = path.split(separator: "/").map(String.init)

        var common = 0
        while common < fromParts.count,
              common < toParts.count,
              fromParts[common] == toParts[common] {
            common += 1
        }

        let ups = Array(repeating: "..", count: fromParts.count - common)
        let downs = Array(toParts[common...])
        let result = (ups + downs).joined(separator: "/")
        return result.isEmpty ? "." : result
    }

    // MARK: - 文档生成

    private static func containerXML(opfPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private static func makeMergedXHTML(sections: [String], stylesheets: [String]) -> String {
        let links = stylesheets
            .map { #"<link rel="stylesheet" type="text/css" href="\#($0)"/>"# }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>Merged</title>
        \(links)
        </head>
        <body>
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func makeNavXHTML(
        anchors: [String],
        titles: [String],
        package: EPUBParser.PackageInfo
    ) -> String {
        let items = zip(anchors, titles).map { anchor, title in
            #"<li><a href="\#(mergedFileName)#\#(anchor)">\#(escape(title))</a></li>"#
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>目录</title></head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>目录</h1>
            <ol>
        \(items)
            </ol>
          </nav>
        </body>
        </html>
        """
    }

    private static func makePackageDocument(
        original: EPUBParser.PackageInfo,
        mergedFileName: String
    ) -> String {
        // 保留全部资源声明（图片/字体/CSS），只把 spine 换成合并文件
        var items: [String] = [
            #"<item id="merged" href="\#(mergedFileName)" media-type="application/xhtml+xml"/>"#,
            #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#,
        ]
        for (id, item) in original.manifest where id != "merged" && id != "nav" {
            items.append(
                #"<item id="\#(escape(id))" href="\#(escape(item.href))" media-type="\#(escape(item.mediaType))"/>"#
            )
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(escape(original.identifier ?? "urn:uuid:\(UUID().uuidString)"))</dc:identifier>
            <dc:title>\(escape(original.title ?? "未命名"))</dc:title>
            <dc:language>\(escape(original.language ?? "zh"))</dc:language>
            <dc:creator>\(escape(original.author ?? "未知"))</dc:creator>
            <meta property="dcterms:modified">\(isoTimestamp())</meta>
          </metadata>
          <manifest>
        \(items.joined(separator: "\n"))
          </manifest>
          <spine>
            <itemref idref="merged"/>
          </spine>
        </package>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

enum EPUBMergeError: LocalizedError {
    case invalidEPUB
    case noContent

    var errorDescription: String? {
        switch self {
        case .invalidEPUB: "无法解析该 EPUB，合并失败。"
        case .noContent: "该 EPUB 没有可合并的正文。"
        }
    }
}