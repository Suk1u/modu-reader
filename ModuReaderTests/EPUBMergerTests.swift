//
//  EPUBMergerTests.swift
//  ModuReaderTests
//
//  合并器测试。测试用 EPUB 由代码现场构造，不依赖外部资源文件。
//

import Testing
import Foundation
@testable import ModuReader

@Suite("EPUB 合并")
struct EPUBMergerTests {

    // MARK: - 测试用 EPUB

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static let packageXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">urn:uuid:merger-test</dc:identifier>
        <dc:title>合并测试</dc:title>
        <dc:language>zh</dc:language>
        <dc:creator>测试作者</dc:creator>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
        <item id="css" href="style.css" media-type="text/css"/>
        <item id="img" href="img/a.png" media-type="image/png"/>
      </manifest>
      <spine>
        <itemref idref="c1"/>
        <itemref idref="c2"/>
      </spine>
    </package>
    """

    private static let navXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>目录</title></head>
    <body>
      <nav epub:type="toc">
        <ol>
          <li><a href="c1.xhtml">第一章 起</a></li>
          <li><a href="c2.xhtml#sec">第二章 承</a></li>
        </ol>
      </nav>
    </body>
    </html>
    """

    /// 第一章：使用 `epub:type`、与其他章重复的 `id="top"`、跨章链接。
    private static let chapter1 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"
          xmlns:epub="http://www.idpf.org/2007/ops"
          xml:lang="zh">
    <head>
      <title>第一章 起</title>
      <link rel="stylesheet" href="style.css"/>
    </head>
    <body class="calibre">
      <section epub:type="chapter" id="top">
        <h1>第一章 起</h1>
        <p id="p1">甲段。</p>
        <p><a href="c2.xhtml#sec">跳到第二章</a></p>
      </section>
    </body>
    </html>
    """

    /// 第二章：同样有 `id="top"`（跨章重复），另有唯一 id `sec` 与图片。
    private static let chapter2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"
          xmlns:epub="http://www.idpf.org/2007/ops"
          xml:lang="zh">
    <head><title>第二章 承</title></head>
    <body class="calibre">
      <section epub:type="chapter" id="top">
        <h1>第二章 承</h1>
        <p id="sec">乙段。</p>
        <p><img src="img/a.png" alt="图"/></p>
      </section>
    </body>
    </html>
    """

    private func makeEPUB() throws -> URL {
        let entries: [SimpleZipWriter.Entry] = [
            .init(path: "mimetype", data: Data("application/epub+zip".utf8)),
            .init(path: "META-INF/container.xml", data: Data(Self.containerXML.utf8)),
            .init(path: "OEBPS/content.opf", data: Data(Self.packageXML.utf8)),
            .init(path: "OEBPS/nav.xhtml", data: Data(Self.navXML.utf8)),
            .init(path: "OEBPS/c1.xhtml", data: Data(Self.chapter1.utf8)),
            .init(path: "OEBPS/c2.xhtml", data: Data(Self.chapter2.utf8)),
            .init(path: "OEBPS/style.css", data: Data("body { margin: 0; }".utf8)),
            .init(path: "OEBPS/img/a.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
        ]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("merger-\(UUID().uuidString).epub")
        try SimpleZipWriter.write(entries: entries, to: url)
        return url
    }

    /// 读出合并产物里的某个条目。
    private func entry(_ path: String, in url: URL) throws -> String {
        let archive = try ZipArchive(url: url)
        let entries = try archive.entries()
        guard let match = entries.first(where: { $0.path == path }) else {
            throw ZipError.entryNotFound(path)
        }
        let data = try archive.data(for: match)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ZipError.decompressionFailed(path)
        }
        return text
    }

    // MARK: - 测试

    @Test("合并结果是良构 XML，且声明了 epub 命名空间")
    func mergedDocumentIsWellFormedXML() throws {
        let source = try makeEPUB()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: output) }

        let summary = try EPUBMerger.buildMerged(from: source, to: output)
        #expect(summary.chapterCount == 2)
        #expect(summary.tocCount == 2)

        let merged = try entry("OEBPS/merged.xhtml", in: output)

        // 根元素必须声明 epub 前缀。
        // 缺少它时 WebKit 会报「Namespace prefix epub for type」并只渲染到出错行。
        #expect(merged.contains("xmlns:epub=\"http://www.idpf.org/2007/ops\""))

        let parser = XMLParser(data: Data(merged.utf8))
        parser.shouldProcessNamespaces = true
        #expect(parser.parse(), "合并文档必须是良构 XML")
    }

    @Test("跨章重复的 id 加前缀，唯一 id 保持不变")
    func namespacesDuplicateIdentifiers() throws {
        let source = try makeEPUB()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try EPUBMerger.buildMerged(from: source, to: output)
        let merged = try entry("OEBPS/merged.xhtml", in: output)

        #expect(merged.contains("id=\"c0-top\""))
        #expect(merged.contains("id=\"c1-top\""))
        #expect(!merged.contains("id=\"top\""))

        // 唯一 id 与出版方的 `#id` 选择器有关，不能被改名
        #expect(merged.contains("id=\"p1\""))
        #expect(merged.contains("id=\"sec\""))
    }

    @Test("跨章链接改写为同文档锚点")
    func rewritesCrossChapterLinks() throws {
        let source = try makeEPUB()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try EPUBMerger.buildMerged(from: source, to: output)
        let merged = try entry("OEBPS/merged.xhtml", in: output)

        // 原链接指向 c2.xhtml#sec，合并后应变成同文档锚点
        #expect(!merged.contains("c2.xhtml"))
        #expect(merged.contains("href=\"#sec\""))
        // 章节起点锚点
        #expect(merged.contains("id=\"ch0\""))
        #expect(merged.contains("id=\"ch1\""))
    }

    @Test("目录标题取自原书 nav，而不是 idref")
    func preservesTOCTitles() throws {
        let source = try makeEPUB()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try EPUBMerger.buildMerged(from: source, to: output)
        let nav = try entry("OEBPS/nav.xhtml", in: output)

        #expect(nav.contains("第一章 起"))
        #expect(nav.contains("第二章 承"))
        #expect(nav.contains("merged.xhtml#ch0"))
        #expect(nav.contains("merged.xhtml#sec"))
    }

    @Test("原章节文件从包内移除，避免链接跳回旧资源")
    func dropsOriginalChapterFiles() throws {
        let source = try makeEPUB()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try EPUBMerger.buildMerged(from: source, to: output)

        let archive = try ZipArchive(url: output)
        let paths = try archive.entries().map { $0.path }
        #expect(!paths.contains("OEBPS/c1.xhtml"))
        #expect(!paths.contains("OEBPS/c2.xhtml"))
        #expect(paths.contains("OEBPS/merged.xhtml"))
        #expect(paths.contains("OEBPS/style.css"))
        #expect(paths.contains("OEBPS/img/a.png"))
        #expect(paths.first == "mimetype", "mimetype 必须是第一个条目")
    }

    @Test("opacity 与 body class 保留")
    func preservesBodyClass() throws {
        let source = try makeEPUB()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try EPUBMerger.buildMerged(from: source, to: output)
        let merged = try entry("OEBPS/merged.xhtml", in: output)

        // 各章 body class 一致时应保留，否则出版方 CSS 的 `.calibre` 规则失效
        #expect(merged.contains("<body class=\"calibre\">"))
        // 样式表只保留一份
        let occurrences = merged.components(separatedBy: "style.css").count - 1
        #expect(occurrences == 1)
    }

    @Test("单资源 EPUB 不合并")
    func rejectsSingleResource() throws {
        let entries: [SimpleZipWriter.Entry] = [
            .init(path: "mimetype", data: Data("application/epub+zip".utf8)),
            .init(path: "META-INF/container.xml", data: Data(Self.containerXML.utf8)),
            .init(path: "OEBPS/content.opf", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:single</dc:identifier>
                <dc:title>单章</dc:title>
                <dc:language>zh</dc:language>
              </metadata>
              <manifest>
                <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="c1"/></spine>
            </package>
            """.utf8)),
            .init(path: "OEBPS/c1.xhtml", data: Data(Self.chapter2.utf8)),
        ]

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-\(UUID().uuidString).epub")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-out-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: output) }
        try SimpleZipWriter.write(entries: entries, to: source)

        do {
            _ = try EPUBMerger.buildMerged(from: source, to: output)
            Issue.record("单资源 EPUB 应抛出 notNeeded")
        } catch EPUBMergeError.notNeeded {
            // 预期
        } catch {
            Issue.record("抛出了意外错误：\(error)")
        }
    }
}