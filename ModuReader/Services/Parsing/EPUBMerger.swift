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
//  合并后 readingOrder 只有一个条目，整本书是一条连续的内容流。
//
//  ── 合并的两个硬约束 ──
//
//  1. 输出必须是**良构 XML**。Readium 以 `application/xhtml+xml` 提供资源，
//     WebKit 用的是 XML 解析器：任何未声明的命名空间前缀（最常见的
//     `epub:type`）都是致命错误，整页只会渲染到出错位置为止。
//     因此合并文档的根元素必须带上各章节 `<html>` 上声明的全部
//     `xmlns:*`，并且生成后要用 XMLParser 验一遍，不合格就放弃合并、
//     回退原书（可读，只是章间需要翻页），绝不把坏文档交给渲染器。
//
//  2. 跨章链接必须改写成同文档内的锚点。原书的 `href="chapter2.xhtml#s3"`
//     在合并后既不能指向已被丢弃的旧文件，也不能产生重复 id。
//     做法：只对**跨章重复**的 id 加 `cN-` 前缀（唯一 id 保持原样，
//     以免破坏出版方的 `#id` 选择器），片段链接随之改写为锚点。
//

import Foundation

enum EPUBMerger {

    /// 合并后的 XHTML 文件名（放在 OPF 同目录）。
    static let mergedFileName = "merged.xhtml"
    /// 重建的目录文件名（放在 OPF 同目录）。
    static let navFileName = "nav.xhtml"

    /// 合并算法版本。
    ///
    /// 引擎把它拼进产物文件名，算法有实质变更时递增即可让旧产物自然失效。
    /// - v2：补全命名空间声明（v1 会让 WebKit 直接报 XML 错误）
    /// - v3：目录写成嵌套 `<ol>`，保留原书层级
    /// - v4：目录可用性改按覆盖率判断；补滚动模式的宽度自适应样式
    /// - v5：滚动模式强制折行（white-space / word-break 覆盖）
    /// - v6：脚注引用「注」去掉可点击性
    static let version = 6

    /// 合并结果统计。
    struct Summary {
        var chapterCount: Int
        var tocCount: Int
    }

    /// 单本合并的字节上限。
    ///
    /// SimpleZipWriter 在内存里拼装整个 ZIP，超大画册式 EPUB 会撑爆内存，
    /// 这种情况宁可放弃合并、回退原书。
    private static let byteLimit = 256 * 1024 * 1024

    // MARK: - 内部模型

    private struct ChapterSource {
        /// 在合并文档中的序号（也是锚点编号）。
        var index: Int
        /// ZIP 内路径。
        var zipPath: String
        /// 规范化后的路径（去百分号编码），用于与目录项对齐。
        var normalizedPath: String
        /// 该章所在目录（改写相对路径用）。
        var directory: String
        /// 完整 XHTML 原文。
        var html: String
        /// `<body>` 上的属性串（用于挑选全局 body class）。
        var bodyAttributes: String
        /// `<body>` 内部内容。
        var bodyHTML: String
        /// 本章声明的全部 id。**改名之前**采集，用于目录锚点映射。
        var ids: Set<String>
        /// 章标题（首个 h1~h3，缺失时用 `<title>`）。
        var heading: String
    }

    private struct TOCItem {
        var title: String
        var zipPath: String
        var fragment: String?
        /// 在原目录里的层级（1 起）。
        var level: Int
    }

    /// 目录节点。保留层级，最终写成嵌套的 `<ol>`。
    private struct NavNode {
        var title: String
        var anchor: String
        var children: [NavNode] = []
    }

    /// 建树前的扁平目录项。
    private struct NavSeed {
        var title: String
        var anchor: String
        var level: Int
    }

    /// 解析出的原始目录项（NCX / nav 共用）。
    private struct RawTOCEntry {
        var title: String
        var href: String
        var level: Int
    }

    // MARK: - 入口

    /// 生成合并版 EPUB。
    ///
    /// - Parameters:
    ///   - source: 原始 .epub。
    ///   - output: 输出的合并版 .epub。
    /// - Returns: 章节数与目录项数。
    static func buildMerged(from source: URL, to output: URL) throws -> Summary {
        let archive = try ZipArchive(url: source)
        let entries = try archive.entries()

        // 内存上限保护
        let totalBytes = entries.reduce(0) { $0 + max(0, $1.uncompressedSize) }
        if totalBytes > byteLimit {
            throw EPUBMergeError.tooLarge
        }

        // 1. container.xml → OPF
        guard let containerEntry = entries.first(where: {
                  $0.path.lowercased() == "meta-inf/container.xml"
              }),
              let containerData = try? archive.data(for: containerEntry),
              let opfPath = try? EPUBParser.parseContainerPath(xml: containerData),
              let opfEntry = findEntry(opfPath, in: entries),
              let opfData = try? archive.data(for: opfEntry) else {
            throw EPUBMergeError.invalidEPUB
        }

        let package = try EPUBParser.parsePackageDocument(xml: opfData)
        let opfDirectory = (opfEntry.path as NSString).deletingLastPathComponent

        // 2. 校验 spine：只接受 XHTML 资源。
        //
        // 固定版式 / 画册式 EPUB 的 spine 里可能有图片或 SVG，
        // 把它们拼进一个文档流会彻底破坏排版，这种情况直接回退原书。
        var spinePaths: [String] = []
        for itemRef in package.spine {
            guard let item = package.manifest[itemRef.idref] else {
                throw EPUBMergeError.invalidEPUB
            }
            let mediaType = item.mediaType.lowercased()
            guard mediaType.contains("xhtml") || mediaType.contains("html") else {
                throw EPUBMergeError.unsupportedLayout
            }
            spinePaths.append(EPUBParser.normalizePath(resolve(item.href, relativeTo: opfDirectory)))
        }

        // 只有一个资源时合并没有意义，也会白白重写一遍文件。
        guard spinePaths.count >= 2 else {
            throw EPUBMergeError.notNeeded
        }

        var spineIndexByPath: [String: Int] = [:]
        for (index, path) in spinePaths.enumerated() {
            spineIndexByPath[path] = index
            // 兼容 ZIP 内使用百分号编码的文件名
            spineIndexByPath[normalize(path)] = index
        }

        // 3. 读取每一章
        var sources: [ChapterSource] = []
        sources.reserveCapacity(spinePaths.count)

        for (index, path) in spinePaths.enumerated() {
            guard let entry = findEntry(path, in: entries),
                  let data = try? archive.data(for: entry),
                  let html = decodeText(data),
                  let body = bodyParts(html) else {
                throw EPUBMergeError.unreadableChapter(path)
            }

            sources.append(
                ChapterSource(
                    index: index,
                    zipPath: entry.path,
                    normalizedPath: path,
                    directory: (entry.path as NSString).deletingLastPathComponent,
                    html: html,
                    bodyAttributes: body.attributes,
                    bodyHTML: normalizeNamedEntities(body.content),
                    ids: ids(in: body.content),
                    heading: firstHeading(in: html)
                )
            )
        }

        // 4. 统计跨章重复的 id
        var idOccurrences: [String: Int] = [:]
        for source in sources {
            for id in source.ids {
                idOccurrences[id, default: 0] += 1
            }
        }
        let duplicatedIDs = Set(idOccurrences.filter { $0.value > 1 }.keys)

        var chapterIDs: [Int: Set<String>] = [:]
        for source in sources {
            chapterIDs[source.index] = source.ids
        }

        // 5. 汇总命名空间 / html 属性 / 样式
        let htmlInfo = collectHTMLInfo(from: sources)
        let styles = collectStyles(from: sources, opfDirectory: opfDirectory)

        // 6. 逐章改写
        var sections: [String] = []
        sections.reserveCapacity(sources.count)

        for source in sources {
            var body = neutralizeNoteReferences(in: source.bodyHTML)
            body = namespaceIDValues(
                in: body,
                prefix: "c\(source.index)-",
                only: duplicatedIDs
            )
            body = rewriteAttributes(
                in: body,
                fromDirectory: source.directory,
                toDirectory: opfDirectory,
                chapterIndex: source.index,
                spineIndexByPath: spineIndexByPath,
                chapterIDs: chapterIDs,
                duplicatedIDs: duplicatedIDs
            )
            body = rewriteInlineStyleURLs(
                in: body,
                fromDirectory: source.directory,
                toDirectory: opfDirectory
            )

            // 空锚点作为章节起点。不用包裹元素，避免破坏 `body > div` 一类选择器。
            sections.append("<a id=\"ch\(source.index)\"></a>\n\(body)")
        }

        // 7. 目录
        let tocItems = extractTOC(
            archive: archive,
            entries: entries,
            package: package,
            opfDirectory: opfDirectory,
            spineIndexByPath: spineIndexByPath
        )

        var titleByPath: [String: String] = [:]
        for item in tocItems where titleByPath[item.zipPath] == nil {
            titleByPath[item.zipPath] = item.title
        }

        // 判断目录是否足以当章节表用。
        //
        // 之前用「条目数 ≥ spine 数」判断，实际会误伤：正常书的目录
        // 本就不会列封面 / 书名页 / 版权页，条目数常少于 spine，
        // 结果整本退回按 spine 取标题，没有 <h1> 的章节就只剩「第 N 章」。
        // 改成看「目录覆盖了多少个 spine 资源」。
        var covered = Set<Int>()
        for item in tocItems {
            if let index = spineIndexByPath[item.zipPath] {
                covered.insert(index)
            }
        }
        let useTOC = covered.count >= 2
            && (covered.count * 2 >= sources.count || sources.count <= 2)

        let flatNav: [NavSeed]
        if useTOC {
            // 目录覆盖得住：直接沿用目录的顺序与标题
            flatNav = tocItems.compactMap { item in
                guard let index = spineIndexByPath[item.zipPath] else { return nil }
                return NavSeed(
                    title: item.title,
                    anchor: anchorID(
                        index: index,
                        fragment: item.fragment,
                        chapterIDs: chapterIDs,
                        duplicatedIDs: duplicatedIDs
                    ),
                    level: item.level
                )
            }
        } else {
            // 目录缺失或不完整：每章一条，标题优先取目录，其次取章内标题。
            flatNav = sources.map { source in
                let title = titleByPath[source.normalizedPath]
                    ?? (source.heading.isEmpty ? "第 \(source.index + 1) 章" : source.heading)
                return NavSeed(title: title, anchor: "ch\(source.index)", level: 0)
            }
        }

        guard !flatNav.isEmpty else {
            throw EPUBMergeError.noContent
        }

        // 还原成树，让阅读器的目录面板能按层级缩进
        let navTree = buildNavTree(flatNav)
        let navCount = countNodes(navTree)

        // 8. 组装文档
        let mergedXHTML = makeMergedXHTML(
            sections: sections,
            stylesheets: styles.links,
            styleBlocks: styles.blocks,
            namespaces: htmlInfo.namespaces,
            htmlAttributes: htmlInfo.attributes,
            bodyAttributes: htmlInfo.bodyAttributes,
            title: package.title ?? "正文"
        )

        // 逐章 `</body>` 拼接后仍可能是坏 XML（实体未声明、标签未闭合）。
        // 交给渲染器只会得到一页「This page contains the following errors」，
        // 所以这里先验，不合格就放弃合并。
        guard isWellFormedXML(mergedXHTML) else {
            throw EPUBMergeError.malformedOutput
        }

        let navXHTML = makeNavXHTML(entries: navTree, title: package.title ?? "目录")

        // manifest 里的 href 是规范化后的路径，条目表里是 ZIP 原始路径，
        // 两边都要收进集合，否则百分号编码不一致时会漏删。
        let droppedPaths = Set(sources.flatMap { [$0.zipPath, $0.normalizedPath] })
        let newOPF = makePackageDocument(
            original: package,
            opfDirectory: opfDirectory,
            droppedPaths: droppedPaths
        )

        // 9. 打包
        var newEntries: [SimpleZipWriter.Entry] = [
            .init(path: "mimetype", data: Data("application/epub+zip".utf8)),
            .init(path: "META-INF/container.xml",
                  data: Data(containerXML(opfPath: opfEntry.path).utf8)),
            .init(path: joined(opfDirectory, mergedFileName), data: Data(mergedXHTML.utf8)),
            .init(path: joined(opfDirectory, navFileName), data: Data(navXHTML.utf8)),
            .init(path: opfEntry.path, data: Data(newOPF.utf8)),
        ]

        let replaced = Set(newEntries.map { $0.path })
        for entry in entries {
            if entry.isDirectory { continue }
            if replaced.contains(entry.path) { continue }
            if droppedPaths.contains(entry.path) { continue }
            guard let data = try? archive.data(for: entry) else { continue }
            newEntries.append(.init(path: entry.path, data: data))
        }

        try SimpleZipWriter.write(entries: newEntries, to: output)

        Diagnostics.log(
            "EPUBMerger: 合并 \(sources.count) 章 / \(navCount) 目录项 → \(output.lastPathComponent)"
        )

        return Summary(chapterCount: sources.count, tocCount: navCount)
    }

    // MARK: - 读取辅助

    /// 在条目表里按路径查找，兼容百分号编码差异。
    private static func findEntry(_ path: String, in entries: [ZipEntry]) -> ZipEntry? {
        if let exact = entries.first(where: { $0.path == path }) {
            return exact
        }
        let decoded = path.removingPercentEncoding ?? path
        if let decodedMatch = entries.first(where: { $0.path == decoded }) {
            return decodedMatch
        }
        let encoded = decoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? decoded
        return entries.first(where: { $0.path == encoded })
    }

    /// 解码 XHTML 字节。
    ///
    /// 规范要求 UTF-8，但国内 EPUB 里 GBK 编码的章节并不罕见。
    private static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let result = TextEncodingDetector.detect(data: data)
        guard !result.hasReplacementCharacters else { return nil }
        return result.text
    }

    // MARK: - HTML 拆解

    /// 取出 `<body>` 的属性串与内部内容。
    private static func bodyParts(_ html: String) -> (attributes: String, content: String)? {
        guard let open = html.range(of: "<body", options: .caseInsensitive) else {
            return nil
        }
        guard let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) else {
            return nil
        }
        let openTag = String(html[open.lowerBound..<openEnd.upperBound])
        let attributes = String(openTag.dropFirst("<body".count).dropLast())
        let contentStart = openEnd.upperBound

        if let close = html.range(of: "</body>", options: .caseInsensitive, range: contentStart..<html.endIndex) {
            return (attributes, String(html[contentStart..<close.lowerBound]))
        }
        return (attributes, String(html[contentStart...]))
    }

    /// 解析 `<html ...>` 上的属性。
    private static func htmlTagAttributes(_ html: String) -> [String: String] {
        guard let start = html.range(of: "<html", options: .caseInsensitive),
              let end = html.range(of: ">", range: start.upperBound..<html.endIndex) else {
            return [:]
        }
        return attributes(in: String(html[start.lowerBound..<end.upperBound]))
    }

    /// 解析标签里的 `key="value"` 对（key 统一小写）。
    private static func attributes(in tag: String) -> [String: String] {
        let pattern = "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }

        let ns = tag as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 4 else { continue }
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let value = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2))
                : ns.substring(with: match.range(at: 3))
            result[key] = value
        }
        return result
    }

    /// 收集正文里出现的全部 id。
    private static func ids(in html: String) -> Set<String> {
        let pattern = "\\sid\\s*=\\s*(?:\"([^\"]+)\"|'([^']+)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = html as NSString
        var result = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges >= 3 else { continue }
            let index = match.range(at: 1).location != NSNotFound ? 1 : 2
            result.insert(ns.substring(with: match.range(at: index)))
        }
        return result
    }

    /// 章标题：首个 `<h1>`~`<h3>`，缺失时退到 `<title>`。
    private static func firstHeading(in html: String) -> String {
        let pattern = "<h([1-3])[^>]*>(.*?)</h\\1>"
        if let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let ns = html as NSString
            if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges >= 3 {
                let text = cleanText(ns.substring(with: match.range(at: 2)))
                if !text.isEmpty { return text }
            }
        }

        let titlePattern = "<title[^>]*>(.*?)</title>"
        if let regex = try? NSRegularExpression(
            pattern: titlePattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let ns = html as NSString
            if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges >= 2 {
                return cleanText(ns.substring(with: match.range(at: 1)))
            }
        }
        return ""
    }

    /// 把常见 HTML 命名实体换成数字引用。
    ///
    /// 原章节可能靠 DOCTYPE 的 DTD 声明这些实体；我们抽走 `<body>` 后
    /// DTD 不再存在，`&nbsp;` 之类就变成未声明实体 —— 在 XHTML 下是致命错误。
    /// 数字引用永远合法，转换后两边都能解析。
    private static func normalizeNamedEntities(_ html: String) -> String {
        guard html.contains("&") else { return html }

        let table: [String: String] = [
            "nbsp": "160", "ensp": "8194", "emsp": "8195", "thinsp": "8201", "shy": "173",
            "mdash": "8212", "ndash": "8211", "hellip": "8230", "middot": "183", "bull": "8226",
            "lsquo": "8216", "rsquo": "8217", "ldquo": "8220", "rdquo": "8221",
            "sbquo": "8218", "bdquo": "8222", "laquo": "171", "raquo": "187",
            "lsaquo": "8249", "rsaquo": "8250",
            "copy": "169", "reg": "174", "trade": "8482", "deg": "176",
            "plusmn": "177", "times": "215", "divide": "247",
            "frac12": "189", "frac14": "188", "frac34": "190",
            "sup2": "178", "sup3": "179", "micro": "181",
            "para": "182", "sect": "167", "permil": "8240",
            "dagger": "8224", "Dagger": "8225",
            "euro": "8364", "pound": "163", "yen": "165", "cent": "162", "curren": "164",
            "larr": "8592", "rarr": "8594", "uarr": "8591", "darr": "8593", "harr": "8596",
            "spades": "9824", "clubs": "9827", "hearts": "9829", "diams": "9830",
            "tilde": "732", "macr": "175", "acute": "180", "cedil": "184", "uml": "168",
        ]

        var result = html
        for (name, code) in table {
            result = result.replacingOccurrences(of: "&\(name);", with: "&#\(code);")
        }
        return result
    }

    /// 去标签、解实体、压空白。
    private static func cleanText(_ html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: [.regularExpression]
        )
        let unescaped = unescapeHTML(stripped)
        return unescaped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescapeHTML(_ text: String) -> String {
        var result = text
        let entities: [String: String] = [
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " ",
            "&amp;": "&",
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    // MARK: - 文档级信息

    private struct HTMLInfo {
        var namespaces: [String: String]
        var attributes: String
        var bodyAttributes: String
    }

    /// 汇总各章的命名空间、`<html>` 属性与 `<body>` class。
    private static func collectHTMLInfo(from sources: [ChapterSource]) -> HTMLInfo {
        var namespaces: [String: String] = [:]
        var lang: String?
        var dir: String?
        var prefix: String?
        var classCounts: [String: Int] = [:]

        for source in sources {
            let attrs = htmlTagAttributes(source.html)
            for (key, value) in attrs where key.hasPrefix("xmlns:") {
                let name = String(key.dropFirst("xmlns:".count))
                if namespaces[name] == nil {
                    namespaces[name] = value
                }
            }
            if lang == nil, let value = attrs["xml:lang"] ?? attrs["lang"] {
                lang = value
            }
            if dir == nil, let value = attrs["dir"] {
                dir = value
            }
            if prefix == nil, let value = attrs["epub:prefix"] {
                prefix = value
            }
            if let cls = attributes(in: "<body \(source.bodyAttributes)>")["class"],
               !cls.trimmingCharacters(in: .whitespaces).isEmpty {
                classCounts[cls, default: 0] += 1
            }
        }

        // 至少声明 `epub`：原书用 `epub:type` 时它是必需的。
        if namespaces["epub"] == nil {
            namespaces["epub"] = "http://www.idpf.org/2007/ops"
        }

        var htmlAttributes: [String] = []
        if let lang { htmlAttributes.append("xml:lang=\"\(escape(lang))\"") }
        if let dir { htmlAttributes.append("dir=\"\(escape(dir))\"") }
        if let prefix { htmlAttributes.append("epub:prefix=\"\(escape(prefix))\"") }

        // body class 只在多数章节一致时才沿用，
        // 避免把某一章的 `cover` 之类样式套到全书。
        var bodyAttributes = ""
        if let (value, count) = classCounts.max(by: { $0.value < $1.value }),
           count * 2 >= sources.count {
            bodyAttributes = " class=\"\(escape(value))\""
        }

        return HTMLInfo(
            namespaces: namespaces,
            attributes: htmlAttributes.joined(separator: " "),
            bodyAttributes: bodyAttributes
        )
    }

    private struct Styles {
        var links: [String]
        var blocks: [String]
    }

    /// 收集各章 `<link rel="stylesheet">`（去重）与 `<style>` 块。
    private static func collectStyles(
        from sources: [ChapterSource],
        opfDirectory: String
    ) -> Styles {
        var links: [String] = []
        var blocks: [String] = []

        for source in sources {
            for href in stylesheetHrefs(in: source.html) {
                let absolute = resolve(href, relativeTo: source.directory)
                let relative = relativePath(from: opfDirectory, to: absolute)
                if !links.contains(relative) {
                    links.append(relative)
                }
            }

            for block in styleBlocks(in: source.html) {
                // 样式块里的 url(...) 同样相对该章目录，合并后必须改写
                let rewritten = rewriteCSSURLs(
                    in: block,
                    fromDirectory: source.directory,
                    toDirectory: opfDirectory,
                    quote: "\""
                )
                if !blocks.contains(rewritten) {
                    blocks.append(rewritten)
                }
            }
        }
        return Styles(links: links, blocks: blocks)
    }

    private static func stylesheetHrefs(in html: String) -> [String] {
        let patterns = [
            "<link[^>]*rel\\s*=\\s*[\"']stylesheet[\"'][^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>",
            "<link[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*rel\\s*=\\s*[\"']stylesheet[\"'][^>]*>",
        ]

        var results: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            where match.numberOfRanges >= 2 {
                let href = ns.substring(with: match.range(at: 1))
                if !results.contains(href) {
                    results.append(href)
                }
            }
        }
        return results
    }

    private static func styleBlocks(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<style[^>]*>.*?</style>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - 改写

    /// 去掉脚注引用（`epub:type="noteref"`）的可点击性。
    ///
    /// 合并后这些「注」链接经常跳到错误位置：锚点经过改写、且脚注正文
    /// 本身就在段落下方。让链接失效，读者直接读下方注释即可。
    private static func neutralizeNoteReferences(in html: String) -> String {
        var edits: [(range: Range<String.Index>, replacement: String)] = []
        var searchStart = html.startIndex

        while let tagStart = html.range(
            of: "<a",
            options: .caseInsensitive,
            range: searchStart..<html.endIndex
        ) {
            guard let tagEnd = html.range(of: ">", range: tagStart.upperBound..<html.endIndex) else {
                break
            }
            let tag = String(html[tagStart.lowerBound..<tagEnd.upperBound])

            if tag.lowercased().contains("noteref"),
               let stripped = removingHref(from: tag) {
                edits.append((tagStart.lowerBound..<tagEnd.upperBound, stripped))
            }
            searchStart = tagEnd.upperBound
        }

        guard !edits.isEmpty else { return html }

        var result = html
        for edit in edits.reversed() {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return result
    }

    /// 去掉标签里的 `href="..."`，保留 id 与其余属性。
    private static func removingHref(from tag: String) -> String? {
        guard let href = tag.range(of: "href", options: .caseInsensitive) else { return nil }

        var index = href.upperBound
        while index < tag.endIndex, tag[index] == " " {
            index = tag.index(after: index)
        }
        guard index < tag.endIndex, tag[index] == "=" else { return nil }
        index = tag.index(after: index)
        while index < tag.endIndex, tag[index] == " " {
            index = tag.index(after: index)
        }
        guard index < tag.endIndex, tag[index] == "\"" || tag[index] == "'" else { return nil }

        let quote = tag[index]
        let valueStart = tag.index(after: index)
        guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else { return nil }
        let end = tag.index(after: valueEnd)

        return tag.replacingCharacters(in: href.lowerBound..<end, with: "")
    }

    /// 给**跨章重复**的 id 加前缀。
    ///
    /// 只改重复项：唯一 id 保持原样，出版方 CSS 里的 `#id` 选择器不受影响；
    /// 重复 id 本来就会让 `getElementById` 取错元素，改名反而修正了歧义。
    private static func namespaceIDValues(
        in html: String,
        prefix: String,
        only ids: Set<String>
    ) -> String {
        guard !ids.isEmpty else { return html }

        let pattern = "(\\sid\\s*=\\s*)(\"([^\"]+)\"|'([^']+)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        let ns = html as NSString
        let result = NSMutableString(string: html)
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 5 else { continue }
            let attributePrefix = ns.substring(with: match.range(at: 1))
            let valueIndex = match.range(at: 3).location != NSNotFound ? 3 : 4
            let value = ns.substring(with: match.range(at: valueIndex))
            guard ids.contains(value) else { continue }

            result.replaceCharacters(
                in: match.range,
                with: "\(attributePrefix)\"\(prefix)\(value)\""
            )
        }
        return result as String
    }

    /// 改写 `src` / `href` / `poster`。
    private static func rewriteAttributes(
        in html: String,
        fromDirectory: String,
        toDirectory: String,
        chapterIndex: Int,
        spineIndexByPath: [String: Int],
        chapterIDs: [Int: Set<String>],
        duplicatedIDs: Set<String>
    ) -> String {
        let pattern = "(src|href|poster)\\s*=\\s*([\"'])(.*?)\\2"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return html }

        let ns = html as NSString
        let result = NSMutableString(string: html)
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let attribute = ns.substring(with: match.range(at: 1))
            let raw = ns.substring(with: match.range(at: 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !raw.isEmpty, !isExternal(raw) else { continue }

            var path = raw
            var fragment: String?
            if let hash = path.firstIndex(of: "#") {
                fragment = String(path[path.index(after: hash)...])
                path = String(path[..<hash])
            }

            // 纯锚点：同文档内跳转
            if path.isEmpty {
                guard let fragment, !fragment.isEmpty else { continue }
                let anchor = anchorID(
                    index: chapterIndex,
                    fragment: fragment,
                    chapterIDs: chapterIDs,
                    duplicatedIDs: duplicatedIDs
                )
                result.replaceCharacters(in: match.range, with: "\(attribute)=\"#\(anchor)\"")
                continue
            }

            let absolute = resolve(path, relativeTo: fromDirectory)
            let key = EPUBParser.normalizePath(absolute)

            if let targetIndex = spineIndexByPath[key] ?? spineIndexByPath[normalize(absolute)] {
                // 指向另一个章节：改成同文档锚点，否则会跳到已丢弃的旧文件
                let anchor = anchorID(
                    index: targetIndex,
                    fragment: fragment,
                    chapterIDs: chapterIDs,
                    duplicatedIDs: duplicatedIDs
                )
                result.replaceCharacters(in: match.range, with: "\(attribute)=\"#\(anchor)\"")
                continue
            }

            // 普通资源：改成相对合并文件位置的路径
            let rewritten = relativePath(from: toDirectory, to: absolute)
            guard rewritten != path else { continue }
            let suffix = fragment.map { "#\($0)" } ?? ""
            result.replaceCharacters(in: match.range, with: "\(attribute)=\"\(rewritten)\(suffix)\"")
        }

        return result as String
    }

    /// 改写 `style="background:url(...)"` 里的路径。
    private static func rewriteInlineStyleURLs(
        in html: String,
        fromDirectory: String,
        toDirectory: String
    ) -> String {
        let pattern = "style\\s*=\\s*([\"'])(.*?)\\1"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return html }

        let ns = html as NSString
        let result = NSMutableString(string: html)
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let value = ns.substring(with: match.range(at: 2))
            let rewritten = rewriteCSSURLs(
                in: value,
                fromDirectory: fromDirectory,
                toDirectory: toDirectory,
                // 属性值用双引号包裹，url() 内部必须换成实体，
                // 否则会得到 style="background:url("a.png")" 这种非法 XML。
                quote: "&quot;"
            )
            guard rewritten != value else { continue }
            result.replaceCharacters(in: match.range, with: "style=\"\(rewritten)\"")
        }
        return result as String
    }

    /// 改写 CSS 里的 `url(...)`。
    ///
    /// - Parameter quote: 包裹路径的引号。写进 HTML 属性时要传 `&quot;`，
    ///   否则内层双引号会提前结束属性值，产生非法 XML。
    private static func rewriteCSSURLs(
        in css: String,
        fromDirectory: String,
        toDirectory: String,
        quote: String
    ) -> String {
        let pattern = "url\\(\\s*[\"']?([^\"')]+)[\"']?\\s*\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return css
        }

        let ns = css as NSString
        let result = NSMutableString(string: css)
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length))

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let raw = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !isExternal(raw), !raw.hasPrefix("#") else { continue }

            var path = raw
            var fragment: String?
            if let hash = path.firstIndex(of: "#") {
                fragment = String(path[path.index(after: hash)...])
                path = String(path[..<hash])
            }
            let absolute = resolve(path, relativeTo: fromDirectory)
            let rewritten = relativePath(from: toDirectory, to: absolute)
            guard rewritten != path else { continue }
            let suffix = fragment.map { "#\($0)" } ?? ""
            result.replaceCharacters(in: match.range, with: "url(\(quote)\(rewritten)\(suffix)\(quote))")
        }
        return result as String
    }

    /// 计算某章内片段对应的锚点 id。
    private static func anchorID(
        index: Int,
        fragment: String?,
        chapterIDs: [Int: Set<String>],
        duplicatedIDs: Set<String>
    ) -> String {
        guard let fragment, !fragment.isEmpty else { return "ch\(index)" }
        let value = fragment.removingPercentEncoding ?? fragment
        guard chapterIDs[index]?.contains(value) == true else {
            // 目录里引用了章内不存在的 id —— 退到章首，至少位置正确
            return "ch\(index)"
        }
        return duplicatedIDs.contains(value) ? "c\(index)-\(value)" : value
    }

    private static func isExternal(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("data:")
            || lower.hasPrefix("mailto:")
            || lower.hasPrefix("tel:")
            || lower.hasPrefix("javascript:")
            || lower.hasPrefix("about:")
            || lower.hasPrefix("//")
    }

    // MARK: - 目录解析

    /// 从原始 NCX / nav 文档提取目录项。
    private static func extractTOC(
        archive: ZipArchive,
        entries: [ZipEntry],
        package: EPUBParser.PackageInfo,
        opfDirectory: String,
        spineIndexByPath: [String: Int]
    ) -> [TOCItem] {
        guard let tocPath = tocDocumentPath(package: package, entries: entries, opfDirectory: opfDirectory),
              let entry = findEntry(tocPath, in: entries),
              let data = try? archive.data(for: entry),
              let text = decodeText(data) else {
            Diagnostics.log("EPUBMerger: 未找到可用的 NCX / nav")
            return []
        }

        let raw: [RawTOCEntry]
        if text.range(of: "<navPoint", options: .caseInsensitive) != nil {
            raw = parseNCX(text)
        } else {
            raw = parseNavDocument(text)
        }

        let tocDirectory = (entry.path as NSString).deletingLastPathComponent
        var result: [TOCItem] = []

        for item in raw {
            guard !item.title.isEmpty, !item.href.isEmpty else { continue }
            var path = item.href
            var fragment: String?
            if let hash = path.firstIndex(of: "#") {
                fragment = String(path[path.index(after: hash)...])
                path = String(path[..<hash])
            }
            // 目录指向自身锚点时无法判断归属章节，直接丢弃
            guard !path.isEmpty else { continue }

            let absolute = resolve(path, relativeTo: tocDirectory)
            let key = EPUBParser.normalizePath(absolute)
            guard spineIndexByPath[key] != nil else { continue }

            result.append(
                TOCItem(
                    title: item.title,
                    zipPath: key,
                    fragment: fragment,
                    level: item.level
                )
            )
        }

        Diagnostics.log("EPUBMerger: 目录原文 \(raw.count) 条，可映射 \(result.count) 条")
        return result
    }

    private static func tocDocumentPath(
        package: EPUBParser.PackageInfo,
        entries: [ZipEntry],
        opfDirectory: String
    ) -> String? {
        if let tocID = package.spineTocID, let item = package.manifest[tocID] {
            return resolve(item.href, relativeTo: opfDirectory)
        }
        for item in package.manifest.values
        where item.properties.lowercased().contains("nav") {
            return resolve(item.href, relativeTo: opfDirectory)
        }
        for item in package.manifest.values
        where item.href.lowercased().hasSuffix(".ncx") {
            return resolve(item.href, relativeTo: opfDirectory)
        }
        if let ncx = entries.first(where: { $0.path.lowercased().hasSuffix(".ncx") }) {
            return ncx.path
        }
        // 最后退到常见的 nav.xhtml / toc.xhtml
        for candidate in ["nav.xhtml", "toc.xhtml", "nav.html"] {
            let path = joined(opfDirectory, candidate)
            if entries.contains(where: { $0.path.lowercased() == path.lowercased() }) {
                return path
            }
        }
        return nil
    }

    /// 解析 NCX（EPUB 2）。层级取自 `navPoint` 的嵌套深度。
    private static func parseNCX(_ xml: String) -> [RawTOCEntry] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        let delegate = NCXDelegate()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    /// 解析 EPUB 3 nav 文档。
    ///
    /// 只取 `<nav epub:type="toc">` 里的链接，避免把 landmarks / page-list
    /// 混进目录；层级取自 `<ol>` 的嵌套深度。
    private static func parseNavDocument(_ html: String) -> [RawTOCEntry] {
        guard let data = html.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        let delegate = NavigationDelegate()
        parser.delegate = delegate
        // 目录文档偶尔不是良构 XML，能解析多少算多少
        _ = parser.parse()

        let all = delegate.items
        let tocOnly = all.filter { $0.navType.contains("toc") }
        let chosen = tocOnly.isEmpty ? all : tocOnly
        return chosen.map { RawTOCEntry(title: $0.title, href: $0.href, level: $0.level) }
    }

    /// 把扁平的目录条目还原成树。
    ///
    /// 层级先做一次「不得跳级」的钳制，避免出版方数据里
    /// 1 → 3 这种断档把整棵树建歪。
    private static func buildNavTree(_ flat: [NavSeed]) -> [NavNode] {
        var normalized: [NavSeed] = []
        normalized.reserveCapacity(flat.count)
        // 以第一条的层级为基准归零（NCX / nav 的层级都是从 1 起）
        let base = flat.first?.level ?? 0
        var previous = -1
        for item in flat {
            var level = max(0, item.level - base)
            // 只钳制「跳级」，同级与回退保持原样，否则兄弟节点会被错判成子节点
            if level > previous + 1 {
                level = previous + 1
            }
            normalized.append(NavSeed(title: item.title, anchor: item.anchor, level: level))
            previous = level
        }

        var index = 0

        func parse(level: Int) -> [NavNode] {
            var nodes: [NavNode] = []
            while index < normalized.count {
                let item = normalized[index]
                if item.level < level { break }
                if item.level > level {
                    // 只会深一层；作为当前最后一个节点的子项
                    guard !nodes.isEmpty else { index += 1; continue }
                    let children = parse(level: item.level)
                    nodes[nodes.count - 1].children.append(contentsOf: children)
                    continue
                }
                index += 1
                var node = NavNode(title: item.title, anchor: item.anchor)
                if index < normalized.count, normalized[index].level > level {
                    node.children = parse(level: normalized[index].level)
                }
                nodes.append(node)
            }
            return nodes
        }

        return parse(level: 0)
    }

    private static func countNodes(_ nodes: [NavNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countNodes($1.children) }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - 文档生成

    private static func containerXML(opfPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="\(escape(opfPath))" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private static func makeMergedXHTML(
        sections: [String],
        stylesheets: [String],
        styleBlocks: [String],
        namespaces: [String: String],
        htmlAttributes: String,
        bodyAttributes: String,
        title: String
    ) -> String {
        let declarations = namespaces
            .sorted { $0.key < $1.key }
            .map { "xmlns:\($0.key)=\"\(escape($0.value))\"" }
            .joined(separator: " ")
        let links = stylesheets
            .map { "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(escape($0))\"/>" }
            .joined(separator: "\n  ")
        let blocks = styleBlocks.joined(separator: "\n  ")
        let htmlAttr = htmlAttributes.isEmpty ? "" : " \(htmlAttributes)"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" \(declarations)\(htmlAttr)>
        <head>
          <title>\(escape(title))</title>
          \(links)
          \(blocks)
          <style type="text/css">
          /* 合并版只用于滚动阅读：内容必须跟随视口宽度。
             出版方 CSS 里常见以 em 为单位的固定宽度、以及
             white-space: nowrap / word-break: keep-all 这类禁止折行的写法，
             字号一调大正文就撑出屏幕，表现为可以左右拖动。 */
          html, body {
            width: auto !important;
            min-width: 0 !important;
            max-width: 100% !important;
          }
          /* min-width 会压过 max-width，出版方偶尔会写死一个最小宽度 */
          body * {
            max-width: 100% !important;
            min-width: 0 !important;
          }
          body, body p, body div, body li, body dd, body blockquote, body span {
            white-space: normal !important;
            word-break: normal !important;
            overflow-wrap: anywhere !important;
            word-wrap: break-word !important;
          }
          pre, code, kbd, samp {
            white-space: pre-wrap !important;
            overflow-wrap: anywhere !important;
          }
          </style>
        </head>
        <body\(bodyAttributes)>
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func makeNavXHTML(entries: [NavNode], title: String) -> String {
        let list = renderNavList(entries)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(escape(title))</title></head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>\(escape(title))</h1>
            \(list)
          </nav>
        </body>
        </html>
        """
    }

    /// 递归输出嵌套 `<ol>`。
    ///
    /// Readium 的目录解析器会据此生成带 children 的 Link 树，
    /// 引擎再把层级带给目录面板。
    private static func renderNavList(_ nodes: [NavNode]) -> String {
        var lines: [String] = ["<ol>"]
        for node in nodes {
            let children = node.children.isEmpty ? "" : renderNavList(node.children)
            lines.append(
                "<li><a href=\"\(mergedFileName)#\(escape(node.anchor))\">\(escape(node.title))</a>\(children)</li>"
            )
        }
        lines.append("</ol>")
        return lines.joined(separator: "\n")
    }

    private static func makePackageDocument(
        original: EPUBParser.PackageInfo,
        opfDirectory: String,
        droppedPaths: Set<String>
    ) -> String {
        var items: [String] = [
            "<item id=\"modu-merged\" href=\"\(mergedFileName)\" media-type=\"application/xhtml+xml\"/>",
            "<item id=\"modu-nav\" href=\"\(navFileName)\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
        ]

        for (id, item) in original.manifest.sorted(by: { $0.key < $1.key }) {
            // 原章节文件已从包里移除，manifest 里不能再留着
            let absolute = resolve(item.href, relativeTo: opfDirectory)
            let key = EPUBParser.normalizePath(absolute)
            if droppedPaths.contains(key) { continue }
            // 旧目录文档由我们重建，避免出现两个 nav
            if item.properties.lowercased().contains("nav") { continue }
            if item.href == mergedFileName || item.href == navFileName { continue }

            let properties = item.properties.isEmpty
                ? ""
                : " properties=\"\(escape(item.properties))\""
            items.append(
                "<item id=\"\(escape(id))\" href=\"\(escape(item.href))\" media-type=\"\(escape(item.mediaType))\"\(properties)/>"
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
            \(items.joined(separator: "\n    "))
          </manifest>
          <spine>
            <itemref idref="modu-merged"/>
          </spine>
        </package>
        """
    }

    // MARK: - 校验

    /// 用 XMLParser 验证良构性。
    ///
    /// 与 WebKit 在 `application/xhtml+xml` 下的解析要求一致：
    /// 命名空间前缀必须已声明、标签必须闭合、实体必须可解析。
    private static func isWellFormedXML(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        return parser.parse()
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

    /// 目录下的文件路径（避免空目录拼出前导斜杠）。
    private static func joined(_ directory: String, _ file: String) -> String {
        directory.isEmpty ? file : "\(directory)/\(file)"
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

    // MARK: - NCX

    private final class NCXDelegate: NSObject, XMLParserDelegate {

        private struct Point {
            var label: String?
            var src: String?
            var level: Int
        }

        private(set) var items: [RawTOCEntry] = []
        private var stack: [Point] = []
        private var capturing = false
        private var buffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName.lowercased() {
            case "navpoint":
                // 入栈后才算层级：第一个 navPoint 为 1
                stack.append(Point(label: nil, src: nil, level: stack.count + 1))
            case "text":
                capturing = true
                buffer = ""
            case "content":
                if let src = attributeDict["src"], !stack.isEmpty {
                    stack[stack.count - 1].src = src
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturing else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName.lowercased() {
            case "text":
                capturing = false
                let text = EPUBMerger.collapseWhitespace(buffer)
                if !text.isEmpty, !stack.isEmpty, stack[stack.count - 1].label == nil {
                    stack[stack.count - 1].label = text
                }
                buffer = ""
            case "navpoint":
                guard let point = stack.popLast() else { return }
                if let label = point.label, let src = point.src {
                    items.append(RawTOCEntry(title: label, href: src, level: point.level))
                }
            default:
                break
            }
        }
    }

    // MARK: - EPUB 3 nav

    private final class NavigationDelegate: NSObject, XMLParserDelegate {

        struct Item {
            var title: String
            var href: String
            var level: Int
            var navType: String
        }

        private(set) var items: [Item] = []
        private var olDepth = 0
        private var navTypes: [String] = []
        private var anchorHref: String?
        private var anchorLevel = 1
        private var buffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName.lowercased() {
            case "nav":
                // 关闭命名空间处理后，属性名仍是 `epub:type`
                let type = (attributeDict["epub:type"] ?? attributeDict["type"] ?? "").lowercased()
                navTypes.append(type)
                olDepth = 0
            case "ol":
                olDepth += 1
            case "a":
                if let href = attributeDict["href"] {
                    anchorHref = href
                    anchorLevel = max(1, olDepth)
                    buffer = ""
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard anchorHref != nil else { return }
            buffer += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName.lowercased() {
            case "a":
                if let href = anchorHref {
                    let title = EPUBMerger.collapseWhitespace(buffer)
                    if !title.isEmpty {
                        items.append(
                            Item(
                                title: title,
                                href: href,
                                level: anchorLevel,
                                navType: navTypes.last ?? ""
                            )
                        )
                    }
                }
                anchorHref = nil
                buffer = ""
            case "ol":
                olDepth = max(0, olDepth - 1)
            case "nav":
                if !navTypes.isEmpty { navTypes.removeLast() }
                olDepth = 0
            default:
                break
            }
        }
    }
}

enum EPUBMergeError: LocalizedError {
    case invalidEPUB
    case noContent
    case notNeeded
    case unsupportedLayout
    case unreadableChapter(String)
    case tooLarge
    case malformedOutput

    var errorDescription: String? {
        switch self {
        case .invalidEPUB:
            "无法解析该 EPUB，合并失败。"
        case .noContent:
            "该 EPUB 没有可合并的正文。"
        case .notNeeded:
            "该 EPUB 只有单个资源，无需合并。"
        case .unsupportedLayout:
            "该 EPUB 为固定版式，不支持合并。"
        case .unreadableChapter(let path):
            "章节「\(path)」无法读取，已放弃合并。"
        case .tooLarge:
            "该 EPUB 体积过大，已放弃合并。"
        case .malformedOutput:
            "合并后的文档不是良构 XML，已放弃合并。"
        }
    }
}