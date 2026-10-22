//
//  TextEPUBBuilder.swift
//  ModuReader
//
//  把 TXT / Markdown 的章节打包成标准 EPUB，交给 Readium 渲染。
//
//  ── 为什么要转换 ──
//
//  TXT 与 EPUB 走两套渲染引擎意味着两套排版、滚动、配色、页码实现，
//  自研的 TextKit 滚动层反复出现问题（空白页、宽度为零、行距失效）。
//
//  转成标准 EPUB 后，TXT 与 EPUB 共用 Readium 的 WKWebView 渲染，
//  连续滚动、页数统计、主题配色、字体回退全部一致。
//

import Foundation

enum TextEPUBBuilder {

    /// 生成（或复用）TXT 书籍对应的 EPUB。
    ///
    /// - Returns: 生成的 .epub 文件路径。
    static func buildIfNeeded(fileStore: FileStore, book: BookDescriptor) throws -> URL {
        let bookDirectory = fileStore.bookDirectory(for: book.id)
        let outputURL = bookDirectory.appendingPathComponent("generated.epub")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let index = try fileStore.readIndex(for: book.id)
        let metadata = (try? fileStore.readMeta(for: book.id))
            ?? PublicationMetadata(title: book.title)

        var entries: [SimpleZipWriter.Entry] = []

        // 1. mimetype（必须是第一个且不压缩）
        entries.append(
            SimpleZipWriter.Entry(
                path: "mimetype",
                data: Data("application/epub+zip".utf8)
            )
        )

        // 2. container.xml
        entries.append(
            SimpleZipWriter.Entry(
                path: "META-INF/container.xml",
                data: Data(containerXML.utf8)
            )
        )

        // 3. 样式表
        entries.append(
            SimpleZipWriter.Entry(
                path: "OEBPS/style.css",
                data: Data(stylesheet.utf8)
            )
        )

        // 4. 逐章 XHTML
        var manifestItems: [String] = []
        var spineItems: [String] = []
        var navItems: [String] = []

        for record in index.chapters {
            let text = (try? fileStore.readChapter(for: book.id, fileName: record.file)) ?? ""
            let xhtml = makeChapterXHTML(title: record.title, body: text)
            let name = "chapter-\(String(format: "%04d", record.index)).xhtml"

            entries.append(
                SimpleZipWriter.Entry(
                    path: "OEBPS/\(name)",
                    data: Data(xhtml.utf8)
                )
            )

            manifestItems.append(
                #"<item id="c\#(record.index)" href="\#(name)" media-type="application/xhtml+xml"/>"#
            )
            spineItems.append(#"<itemref idref="c\#(record.index)"/>"#)
            navItems.append(
                #"<li><a href="\#(name)">\#(escape(record.title))</a></li>"#
            )
        }

        // 5. nav.xhtml
        entries.append(
            SimpleZipWriter.Entry(
                path: "OEBPS/nav.xhtml",
                data: Data(navXHTML(items: navItems, title: metadata.title).utf8)
            )
        )

        // 6. content.opf
        let opf = packageDocument(
            metadata: metadata,
            manifestItems: manifestItems,
            spineItems: spineItems
        )
        entries.append(
            SimpleZipWriter.Entry(
                path: "OEBPS/content.opf",
                data: Data(opf.utf8)
            )
        )

        try SimpleZipWriter.write(entries: entries, to: outputURL)
        Diagnostics.log("TextEPUBBuilder: 已生成 \(outputURL.lastPathComponent)（\(index.chapters.count) 章）")
        return outputURL
    }

    // MARK: - 文档模板

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// 出版方样式表。
    ///
    /// 刻意保持极简：不设置 font-family 与颜色，
    /// 这样 Readium 的用户偏好（字号/字体/主题）能完全覆盖。
    private static let stylesheet = """
    html, body { margin: 0; padding: 0; }
    body { line-height: 1.6; }
    p { margin: 0 0 0.8em 0; text-indent: 2em; }
    h1, h2 { text-indent: 0; }
    """

    private static func navXHTML(items: [String], title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(escape(title))</title></head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>目录</h1>
            <ol>
        \(items.joined(separator: "\n"))
            </ol>
          </nav>
        </body>
        </html>
        """
    }

    private static func packageDocument(
        metadata: PublicationMetadata,
        manifestItems: [String],
        spineItems: [String]
    ) -> String {
        let identifier = metadata.identifier ?? "urn:uuid:\(UUID().uuidString)"
        let language = metadata.language ?? "zh"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(escape(identifier))</dc:identifier>
            <dc:title>\(escape(metadata.title))</dc:title>
            <dc:language>\(escape(language))</dc:language>
            <dc:creator>\(escape(metadata.author ?? "未知"))</dc:creator>
            <meta property="dcterms:modified">\(isoTimestamp())</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>
        \(manifestItems.joined(separator: "\n"))
          </manifest>
          <spine>
        \(spineItems.joined(separator: "\n"))
          </spine>
        </package>
        """
    }

    private static func makeChapterXHTML(title: String, body: String) -> String {
        // 按行切段落：TXT 的段落以换行分隔
        let paragraphs = body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<p>\(escape($0))</p>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>\(escape(title))</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
          <h2>\(escape(title))</h2>
        \(paragraphs)
        </body>
        </html>
        """
    }

    // MARK: - Helpers

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