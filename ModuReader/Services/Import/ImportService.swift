//
//  ImportService.swift
//  ModuReader
//
//  导入流程：安全范围访问 → 复制到沙盒 → 嗅探格式 → 解析 → 写入数据库。
//

import Foundation
import SwiftData

/// 导入错误。
enum ImportError: LocalizedError {
    case accessDenied
    case unsupportedFormat(String)
    case copyFailed(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "无法访问该文件。请确认文件存在，且已允许本 App 访问。"
        case .unsupportedFormat(let ext):
            "暂不支持 .\(ext) 格式。当前版本仅支持 TXT 与 Markdown。"
        case .copyFailed(let reason):
            "复制文件失败：\(reason)"
        case .parseFailed(let reason):
            "解析失败：\(reason)"
        }
    }
}

/// 导入结果。
struct ImportResult: Sendable {
    var bookID: UUID
    var title: String
    var chapterCount: Int
    var detectedEncoding: String
}

/// 导入服务。
///
/// 隔离说明：
/// - 类本身 `@MainActor`，因为要操作 `ModelContext`。
/// - 文件读写与解析通过 `Task.detached` 放到后台，避免大文件阻塞主线程。
/// - 安全范围访问必须在**调用方的同一线程**上开始并结束，
///   因此 scope 的开启/关闭放在 `importFile` 入口与 `defer`，不跨任务边界。
@MainActor
final class ImportService {

    private let fileStore: FileStore
    private let modelContext: ModelContext

    init(fileStore: FileStore, modelContext: ModelContext) {
        self.fileStore = fileStore
        self.modelContext = modelContext
    }

    /// 导入一个文件。
    ///
    /// - Parameters:
    ///   - url: 已复制到沙盒的文件 URL（通常是 `StageFile` 的暂存副本）。
    ///     传暂存副本而非原始 picker URL，是因为 picker 的安全范围授权
    ///     在回调返回后可能失效。
    ///   - originalFileName: 原始文件名，用于推导书名。为 nil 时从 `url` 推导。
    ///   - forcedEncoding: 手动指定的编码（为 nil 时自动探测）。
    /// - Returns: 导入结果。
    func importFile(
        at url: URL,
        originalFileName: String? = nil,
        forcedEncoding: String.Encoding? = nil
    ) async throws -> ImportResult {
        // 1. 安全范围访问
        //
        // 返回 false 不等于失败：沙盒内的 URL（例如从 openURL 传入的 Inbox 副本）
        // 不需要安全范围，此时返回 false 但文件仍可读。
        // 真正判断能否读取靠下面的 isReadableFile 检查。
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 2. 可读性前置校验
        //
        // 注意：不能只看 isReadableFile。iCloud Drive 上的文件可能是
        // 「已下载但未物化」的占位符，此时可读但读取会触发下载。
        // 这里同时检查文件大小，为 0 时明确报错。
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ImportError.accessDenied
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw ImportError.copyFailed("文件为空或尚未从 iCloud 下载完成。")
        }

        // 3. 嗅探格式
        let format = FormatSniffer.sniff(url: url)
        guard format.isSupportedInCurrentMilestone else {
            throw ImportError.unsupportedFormat(url.pathExtension.lowercased())
        }

        // 4. 复制到沙盒
        //
        // 沙盒内统一命名为 source.<ext>：原始文件名可能含路径分隔符、
        // 控制字符或超长 UTF-8，直接用作路径不安全。
        // 书名在解析时通过 displayTitle 单独传入，不受改名影响。
        let bookID = UUID()
        try fileStore.prepareBookDirectory(for: bookID)

        let ext = url.pathExtension.lowercased()
        let sourceName = ext.isEmpty ? "source.txt" : "source.\(ext)"
        let destination = fileStore.bookDirectory(for: bookID).appendingPathComponent(sourceName)

        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            try? fileStore.deleteBook(bookID)
            throw ImportError.copyFailed(error.localizedDescription)
        }

        // 5. 按格式分派解析（在后台执行，避免大文件阻塞主线程）
        do {
            switch format {
            case .epub:
                return try await importEPUB(
                    source: destination,
                    bookID: bookID,
                    originalFileName: originalFileName
                )
            default:
                return try await importPlainText(
                    source: destination,
                    bookID: bookID,
                    ext: ext,
                    originalFileName: originalFileName,
                    forcedEncoding: forcedEncoding
                )
            }
        } catch {
            try? fileStore.deleteBook(bookID)
            throw error
        }
    }

    // MARK: - Plain text

    private func importPlainText(
        source: URL,
        bookID: UUID,
        ext: String,
        originalFileName: String?,
        forcedEncoding: String.Encoding?
    ) async throws -> ImportResult {
        let parser = TextPublicationParser(fileStore: fileStore)

        // 书名来源优先级：
        // 1. 调用方显式传入的 originalFileName（真实导入路径）
        // 2. 沙盒副本的文件名
        //
        // 沙盒副本统一叫 source.<ext>，所以第 2 条会得到 "source"。
        // 这是给测试和调试路径用的兜底，不是正常情况。
        let title: String
        if let originalFileName {
            title = TextPublicationParser.deriveTitle(from: originalFileName)
        } else {
            Diagnostics.log("ImportService: 未传 originalFileName，书名将回退为副本名")
            title = TextPublicationParser.deriveTitle(from: source.lastPathComponent)
        }

        let parsed: ParsedTextPublication
        do {
            parsed = try await Task.detached(priority: .userInitiated) {
                try await parser.parse(
                    url: source,
                    bookID: bookID,
                    displayTitle: title,
                    forcedEncoding: forcedEncoding
                )
            }.value
        } catch {
            throw ImportError.parseFailed(error.localizedDescription)
        }

        let entity = BookEntity(
            id: bookID,
            title: parsed.metadata.title,
            author: parsed.metadata.author,
            kind: .text,
            formatExtension: ext.isEmpty ? "txt" : ext,
            relativePath: bookID.uuidString,
            totalCharacters: parsed.totalCharacters,
            chapterCount: parsed.chapters.count,
            lastOpenedAt: Date(),
            detectedEncoding: parsed.detectedEncodingName
        )
        try persist(entity)

        return ImportResult(
            bookID: bookID,
            title: parsed.metadata.title,
            chapterCount: parsed.chapters.count,
            detectedEncoding: parsed.detectedEncodingName
        )
    }

    // MARK: - EPUB

    private func importEPUB(
        source: URL,
        bookID: UUID,
        originalFileName: String?
    ) async throws -> ImportResult {
        let parser = EPUBParser(fileStore: fileStore)

        let parsed: ParsedEPUB
        do {
            parsed = try await Task.detached(priority: .userInitiated) {
                try await parser.parse(url: source, bookID: bookID)
            }.value
        } catch {
            throw ImportError.parseFailed(error.localizedDescription)
        }

        // 书名：优先用 EPUB 内嵌元数据，缺失时回退文件名
        let fallbackTitle = TextPublicationParser.deriveTitle(
            from: originalFileName ?? source.lastPathComponent
        )
        let title = parsed.metadata.title.isEmpty ? fallbackTitle : parsed.metadata.title

        let entity = BookEntity(
            id: bookID,
            title: title,
            author: parsed.metadata.author,
            kind: parsed.isFixedLayout ? .epubFixedLayout : .epubReflowable,
            formatExtension: "epub",
            relativePath: bookID.uuidString,
            coverPath: parsed.coverFileName,
            totalCharacters: parsed.totalCharacters,
            chapterCount: parsed.chapters.count,
            lastOpenedAt: Date(),
            detectedEncoding: "EPUB"
        )
        try persist(entity)

        return ImportResult(
            bookID: bookID,
            title: title,
            chapterCount: parsed.chapters.count,
            detectedEncoding: "EPUB"
        )
    }

    // MARK: - Persistence

    private func persist(_ entity: BookEntity) throws {
        modelContext.insert(entity)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(entity)
            throw ImportError.parseFailed("保存书籍信息失败：\(error.localizedDescription)")
        }
    }

    /// 删除一本书（数据库 + 文件）。
    func deleteBook(_ entity: BookEntity) throws {
        let bookID = entity.id
        modelContext.delete(entity)
        try modelContext.save()
        try? fileStore.deleteBook(bookID)
    }
}
