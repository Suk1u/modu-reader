//
//  ImportServiceTests.swift
//  ModuReaderTests
//
//  导入链路测试：文件 → 嗅探 → 复制 → 解析 → 落盘。
//  这些用例覆盖「导入没反应」背后最可能出问题的服务层逻辑。
//

import Testing
import Foundation
import SwiftData
@testable import ModuReader

@Suite("导入链路")
@MainActor
struct ImportServiceTests {

    /// 构造一个隔离的测试环境。
    private func makeEnvironment() throws -> (ImportService, FileStore, ModelContext, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModuTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = try FileStore(rootURL: root)
        let container = try ModuModelContainer.makeInMemory()
        let context = ModelContext(container)
        let service = ImportService(fileStore: store, modelContext: context)
        return (service, store, context, root)
    }

    private func writeTempFile(_ text: String, ext: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModuSource-\(UUID().uuidString).\(ext)")
        guard let data = text.data(using: encoding) else {
            throw ImportError.parseFailed("测试文本无法编码")
        }
        try data.write(to: url)
        return url
    }

    @Test("导入 UTF-8 TXT 成功")
    func importUTF8Text() async throws {
        let (service, _, context, _) = try makeEnvironment()
        let text = """
        第一章 开始
        这是第一章的内容。

        第二章 继续
        这是第二章的内容。

        第三章 结束
        这是第三章的内容。
        """
        let url = try writeTempFile(text, ext: "txt")

        let result = try await service.importFile(at: url)

        #expect(result.chapterCount == 3)
        // 未传 originalFileName 时，书名回退到沙盒副本名 source.txt
        #expect(result.title == "source")

        let books = try context.fetch(FetchDescriptor<BookEntity>())
        #expect(books.count == 1)
        #expect(books[0].chapterCount == 3)
        #expect(books[0].totalCharacters > 0)
    }

    @Test("导入 GBK TXT 成功且无乱码")
    func importGBKText() async throws {
        let (service, _, context, _) = try makeEnvironment()
        let text = """
        第一章 开始
        这是中文内容测试。

        第二章 继续
        更多中文内容。

        第三章 结束
        最后一段中文。
        """
        let gbEncoding = TextEncodingDetector.encoding(from: .GB_18030_2000)
        let url = try writeTempFile(text, ext: "txt", encoding: gbEncoding)

        let result = try await service.importFile(at: url)
        #expect(result.chapterCount == 3)

        let books = try context.fetch(FetchDescriptor<BookEntity>())
        #expect(books[0].detectedEncoding?.contains("GB") ?? false)
    }

    @Test("章节正文正确落盘")
    func chaptersWrittenToDisk() async throws {
        let (service, store, _, _) = try makeEnvironment()
        let text = """
        第一章 甲
        甲的内容。

        第二章 乙
        乙的内容。

        第三章 丙
        丙的内容。
        """
        let url = try writeTempFile(text, ext: "txt")
        let result = try await service.importFile(at: url)

        let index = try store.readIndex(for: result.bookID)
        #expect(index.chapters.count == 3)

        let firstChapter = try store.readChapter(
            for: result.bookID,
            fileName: index.chapters[0].file
        )
        #expect(firstChapter.contains("甲的内容"))
    }

    @Test("不支持的格式抛出明确错误")
    func unsupportedFormat() async throws {
        let (service, _, _, _) = try makeEnvironment()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7\n".utf8).write(to: url)

        await #expect(throws: ImportError.self) {
            try await service.importFile(at: url)
        }
    }

    @Test("不存在的文件抛出访问错误")
    func missingFile() async throws {
        let (service, _, _, _) = try makeEnvironment()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).txt")

        await #expect(throws: ImportError.self) {
            try await service.importFile(at: url)
        }
    }

    @Test("导入失败时不留下半成品目录")
    func failedImportCleansUp() async throws {
        let (service, store, context, _) = try makeEnvironment()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7\n".utf8).write(to: url)

        _ = try? await service.importFile(at: url)

        let books = try context.fetch(FetchDescriptor<BookEntity>())
        #expect(books.isEmpty)

        let entries = try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)
        #expect(entries.isEmpty)
    }

    @Test("书名取自 originalFileName 参数，而不是沙盒副本名")
    func titleFromOriginalFileName() async throws {
        let (service, _, context, _) = try makeEnvironment()
        let text = """
        第一章 甲
        内容。

        第二章 乙
        内容。

        第三章 丙
        内容。
        """
        let url = try writeTempFile(text, ext: "txt")

        // 模拟真实调用：暂存副本名是 UUID，原始名单独传入
        let result = try await service.importFile(
            at: url,
            originalFileName: "三体.txt"
        )

        #expect(result.title == "三体")

        let books = try context.fetch(FetchDescriptor<BookEntity>())
        #expect(books[0].title == "三体")
    }

    @Test("未传 originalFileName 时回退到文件自身名字")
    func titleFallbackToFileURL() async throws {
        let (service, _, _, _) = try makeEnvironment()
        let text = """
        第一章 甲
        内容。

        第二章 乙
        内容。

        第三章 丙
        内容。
        """
        let url = try writeTempFile(text, ext: "txt")

        let result = try await service.importFile(at: url)

        // 未传 originalFileName 时，书名回退到沙盒副本名 source.txt
        // （真实调用路径一定会传 originalFileName，见 titleFromOriginalFileName）
        #expect(result.title == "source")
    }

    @Test("书名从文件名推导并清理站点后缀")
    func titleDerivation() {
        let cases: [(String, String)] = [
            ("/tmp/三体.txt", "三体"),
            ("/tmp/三体_www.example.com.txt", "三体"),
            ("/tmp/无名书.epub", "无名书"),
        ]
        for (path, expected) in cases {
            let url = URL(fileURLWithPath: path)
            #expect(TextPublicationParser.deriveTitle(from: url) == expected)
        }
    }

    @Test("格式嗅探：扩展名伪装为 TXT 的 PDF 被识别")
    func sniffDisguisedPDF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("disguised-\(UUID().uuidString).txt")
        try Data("%PDF-1.7\n".utf8).write(to: url)

        #expect(FormatSniffer.sniff(url: url) == .pdf)
    }

    @Test("格式嗅探：纯文本返回 plainText")
    func sniffPlainText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-\(UUID().uuidString).txt")
        try Data("普通文本内容\n第二行".utf8).write(to: url)

        #expect(FormatSniffer.sniff(url: url) == .plainText)
    }

    @Test("支持的 UTType 包含 txt 与 md")
    func supportedTypes() {
        let identifiers = FormatSniffer.supportedContentTypes.map(\.identifier)
        #expect(identifiers.contains("public.plain-text"))
        #expect(identifiers.contains("public.data"))
    }
}
