//
//  EPUBParserTests.swift
//  ModuReaderTests
//
//  EPUB 解析测试。测试用 EPUB 由代码现场构造，不依赖外部资源文件。
//

import Testing
import Foundation
@testable import ModuReader

@Suite("EPUB 解析")
struct EPUBParserTests {

    // MARK: - 测试用 EPUB 构造

    /// 构造一个最小可用的 EPUB 2 文件。
    private func makeEPUB(
        title: String = "测试书籍",
        author: String = "测试作者",
        chapterCount: Int = 3
    ) throws -> URL {
        var files: [(path: String, content: String)] = []

        // mimetype 必须是第一个条目且不压缩（简化实现：用 store）
        files.append(("mimetype", "application/epub+zip"))

        files.append((
            "META-INF/container.xml",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """
        ))

        var manifestItems = ""
        var spineItems = ""
        for index in 1...chapterCount {
            manifestItems += """
                <item id="chapter\(index)" href="chapter\(index).xhtml" media-type="application/xhtml+xml"/>
            """
            spineItems += """
                <itemref idref="chapter\(index)"/>
            """
            files.append((
                "OEBPS/chapter\(index).xhtml",
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head><title>第\(index)章</title></head>
                <body>
                  <h1>第\(index)章 标题</h1>
                  <p>这是第\(index)章的正文内容。</p>
                  <p>第二段内容，用于测试段落分隔。</p>
                </body>
                </html>
                """
            ))
        }

        files.append((
            "OEBPS/content.opf",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title>
                <dc:creator>\(author)</dc:creator>
                <dc:language>zh</dc:language>
                <dc:identifier id="bookid">urn:uuid:test-\(UUID().uuidString)</dc:identifier>
              </metadata>
              <manifest>
                \(manifestItems)
              </manifest>
              <spine>
                \(spineItems)
              </spine>
            </package>
            """
        ))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).epub")
        try writeZip(files: files, to: url)
        return url
    }

    /// 用最小实现写一个 store 模式的 ZIP。
    private func writeZip(files: [(path: String, content: String)], to url: URL) throws {
        var output = Data()
        var centralDirectory = Data()

        for file in files {
            let nameData = Data(file.path.utf8)
            let contentData = Data(file.content.utf8)
            let crc = Self.crc32(contentData)
            let offset = UInt32(output.count)

            // 本地文件头
            var local = Data()
            local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            local.appendUInt16(20)                    // version needed
            local.appendUInt16(0)                     // flags
            local.appendUInt16(0)                     // method = store
            local.appendUInt16(0)                     // mod time
            local.appendUInt16(0)                     // mod date
            local.appendUInt32(crc)
            local.appendUInt32(UInt32(contentData.count))
            local.appendUInt32(UInt32(contentData.count))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)                     // extra length
            local.append(nameData)
            local.append(contentData)
            output.append(local)

            // 中央目录条目
            var central = Data()
            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.appendUInt16(20)                  // version made by
            central.appendUInt16(20)                  // version needed
            central.appendUInt16(0)                   // flags
            central.appendUInt16(0)                   // method
            central.appendUInt16(0)                   // mod time
            central.appendUInt16(0)                   // mod date
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(contentData.count))
            central.appendUInt32(UInt32(contentData.count))
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)                   // extra
            central.appendUInt16(0)                   // comment
            central.appendUInt16(0)                   // disk number
            central.appendUInt16(0)                   // internal attrs
            central.appendUInt32(0)                   // external attrs
            central.appendUInt32(offset)
            central.append(nameData)
            centralDirectory.append(central)
        }

        let centralOffset = UInt32(output.count)
        output.append(centralDirectory)

        // EOCD
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        eocd.appendUInt16(0)
        eocd.appendUInt16(0)
        eocd.appendUInt16(UInt16(files.count))
        eocd.appendUInt16(UInt16(files.count))
        eocd.appendUInt32(UInt32(centralDirectory.count))
        eocd.appendUInt32(centralOffset)
        eocd.appendUInt16(0)
        output.append(eocd)

        try output.write(to: url)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Tests

    @Test("解析最小 EPUB")
    func parseMinimalEPUB() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBTest-\(UUID().uuidString)", isDirectory: true)
        let store = try FileStore(rootURL: root)
        let parser = EPUBParser(fileStore: store)

        let epubURL = try makeEPUB(chapterCount: 3)
        defer { try? FileManager.default.removeItem(at: epubURL) }

        let bookID = UUID()
        let parsed = try await parser.parse(url: epubURL, bookID: bookID)

        #expect(parsed.metadata.title == "测试书籍")
        #expect(parsed.metadata.author == "测试作者")
        #expect(parsed.chapters.count == 3)
        #expect(parsed.totalCharacters > 0)
    }

    @Test("章节标题与正文正确提取")
    func chapterContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBTest-\(UUID().uuidString)", isDirectory: true)
        let store = try FileStore(rootURL: root)
        let parser = EPUBParser(fileStore: store)

        let epubURL = try makeEPUB(chapterCount: 2)
        defer { try? FileManager.default.removeItem(at: epubURL) }

        let bookID = UUID()
        let parsed = try await parser.parse(url: epubURL, bookID: bookID)

        let firstChapterText = try store.readChapter(
            for: bookID,
            fileName: parsed.chapters[0].filePath
        )

        #expect(firstChapterText.contains("第1章 标题"))
        #expect(firstChapterText.contains("这是第1章的正文内容"))
        #expect(firstChapterText.contains("第二段内容"))
    }

    @Test("章节正文按段落分隔")
    func paragraphsSeparated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBTest-\(UUID().uuidString)", isDirectory: true)
        let store = try FileStore(rootURL: root)
        let parser = EPUBParser(fileStore: store)

        let epubURL = try makeEPUB(chapterCount: 1)
        defer { try? FileManager.default.removeItem(at: epubURL) }

        let bookID = UUID()
        let parsed = try await parser.parse(url: epubURL, bookID: bookID)
        #expect(parsed.chapters.count == 1)

        let text = try store.readChapter(
            for: bookID,
            fileName: parsed.chapters[0].filePath
        )
        // 两段之间应有空行
        #expect(text.contains("\n\n"))
        #expect(text.components(separatedBy: "\n\n").count >= 2)
    }

    @Test("索引文件正确写入")
    func indexWritten() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBTest-\(UUID().uuidString)", isDirectory: true)
        let store = try FileStore(rootURL: root)
        let parser = EPUBParser(fileStore: store)

        let epubURL = try makeEPUB(chapterCount: 3)
        defer { try? FileManager.default.removeItem(at: epubURL) }

        let bookID = UUID()
        let parsed = try await parser.parse(url: epubURL, bookID: bookID)

        let index = try store.readIndex(for: bookID)
        #expect(index.chapters.count == 3)
        #expect(index.totalCharacters == parsed.totalCharacters)

        // 全局偏移应首尾相接
        var expectedStart = 0
        for record in index.chapters {
            #expect(record.globalStart == expectedStart)
            expectedStart += record.characterCount
        }
    }

    @Test("缺少 container.xml 时抛出明确错误")
    func missingContainer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBTest-\(UUID().uuidString)", isDirectory: true)
        let store = try FileStore(rootURL: root)
        let parser = EPUBParser(fileStore: store)

        // 构造一个只有 mimetype 的假 EPUB
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).epub")
        try writeZip(
            files: [("mimetype", "application/epub+zip")],
            to: url
        )
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: EPUBError.self) {
            try await parser.parse(url: url, bookID: UUID())
        }
    }

    @Test("XHTML 转纯文本剥离标签")
    func xhtmlToPlainText() throws {
        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>标题</title><style>body{color:red}</style></head>
        <body>
          <h1>第一章</h1>
          <p>正文第一段。</p>
          <p>正文<b>加粗</b>第二段。</p>
          <script>alert('x')</script>
        </body>
        </html>
        """
        let text = try EPUBParser.extractText(fromXHTML: Data(xhtml.utf8))

        #expect(text.contains("第一章"))
        #expect(text.contains("正文第一段。"))
        #expect(text.contains("正文加粗第二段。"))
        // 脚本与样式必须被剥离
        #expect(!text.contains("alert"))
        #expect(!text.contains("color:red"))
        // 标题标签不应出现在正文里
        #expect(!text.contains("<h1>"))
    }

    @Test("非法 XHTML 退化为正则剥离")
    func malformedXHTMLFallback() throws {
        // 未闭合标签，XMLParser 会失败
        let xhtml = "<html><body><p>第一段<p>第二段<script>bad()</script></body></html>"
        let text = try EPUBParser.extractText(fromXHTML: Data(xhtml.utf8))

        #expect(text.contains("第一段"))
        #expect(text.contains("第二段"))
        #expect(!text.contains("bad()"))
    }

    @Test("ZIP 解压拒绝越界路径")
    func zipSlipProtection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipSlip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slip-\(UUID().uuidString).zip")
        try writeZip(
            files: [("../../../evil.txt", "pwned")],
            to: url
        )
        defer { try? FileManager.default.removeItem(at: url) }

        try EPUBParser.extract(archiveURL: url, to: root)

        // 越界文件不应被写出
        let escaped = root.deletingLastPathComponent()
            .appendingPathComponent("evil.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }
}

// MARK: - Data 写入辅助

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
        ])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}

// MARK: - 图片支持

@Suite("EPUB 图片")
struct EPUBImageTests {

    @Test("img 标签转为图片标记")
    func imgTagBecomesMarker() throws {
        let xhtml = """
        <html><body>
        <p>文字段落。</p>
        <img src="../Images/pic.jpg" alt="插图"/>
        <p>后面的文字。</p>
        </body></html>
        """
        let text = try EPUBParser.extractText(fromXHTML: Data(xhtml.utf8))

        #expect(text.contains("文字段落。"))
        #expect(text.contains("后面的文字。"))

        let references = EPUBParser.imageReferences(in: text)
        #expect(references.count == 1)
        #expect(references[0].source == "../Images/pic.jpg")
    }

    @Test("多张图片都被提取")
    func multipleImages() throws {
        let xhtml = """
        <html><body>
        <img src="a.jpg"/>
        <p>中间</p>
        <img src="b.png"/>
        <img src="c.jpeg"/>
        </body></html>
        """
        let text = try EPUBParser.extractText(fromXHTML: Data(xhtml.utf8))
        let references = EPUBParser.imageReferences(in: text)

        #expect(references.count == 3)
        #expect(references.map(\.source) == ["a.jpg", "b.png", "c.jpeg"])
    }

    @Test("图片路径解析为绝对路径")
    func resolveImagePaths() {
        let text = "段落\n\(EPUBParser.imageMarker(for: "../Images/pic.jpg"))\n结尾"
        let root = URL(fileURLWithPath: "/tmp/book/extracted", isDirectory: true)

        let resolved = EPUBParser.resolveImagePaths(
            in: text,
            chapterDirectory: "OEBPS/Text",
            extractedRoot: root
        )

        let references = EPUBParser.imageReferences(in: resolved)
        #expect(references.count == 1)
        #expect(references[0].source.hasPrefix("/tmp/book/extracted"))
        #expect(references[0].source.hasSuffix("Images/pic.jpg"))
    }

    @Test("移除图片标记后只剩正文")
    func stripMarkers() {
        let text = "前面\n\(EPUBParser.imageMarker(for: "a.jpg"))\n后面"
        let stripped = EPUBParser.strippingImageMarkers(text)

        #expect(!stripped.contains("IMG:"))
        #expect(stripped.contains("前面"))
        #expect(stripped.contains("后面"))
    }

    @Test("外链图片不被本地化")
    func externalImageUntouched() {
        let text = EPUBParser.imageMarker(for: "https://example.com/pic.jpg")
        let root = URL(fileURLWithPath: "/tmp/book", isDirectory: true)

        let resolved = EPUBParser.resolveImagePaths(
            in: text,
            chapterDirectory: "OEBPS",
            extractedRoot: root
        )

        let references = EPUBParser.imageReferences(in: resolved)
        #expect(references.first?.source == "https://example.com/pic.jpg")
    }

    @Test("退化解析路径也能提取 img")
    func fallbackExtractsImages() throws {
        // 未闭合标签，触发正则退化路径
        let xhtml = "<html><body><p>文字<img src=\"pic.png\"><p>后续"
        let text = try EPUBParser.extractText(fromXHTML: Data(xhtml.utf8))

        let references = EPUBParser.imageReferences(in: text)
        #expect(references.count == 1)
        #expect(references[0].source == "pic.png")
        #expect(text.contains("文字"))
    }
}
