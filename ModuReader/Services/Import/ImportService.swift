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
            "无法访问该文件，请检查文件权限。"
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
    ///   - url: 用户通过 `fileImporter` 选择的外部 URL。
    ///   - forcedEncoding: 手动指定的编码（为 nil 时自动探测）。
    /// - Returns: 导入结果。
    func importFile(at url: URL, forcedEncoding: String.Encoding? = nil) async throws -> ImportResult {
        // 1. 安全范围访问
        //
        // 注意：返回 false 不等于失败。沙盒内的 URL（例如从 openURL 传入的
        // Inbox 副本）不需要安全范围，此时返回 false 但文件仍可读。
        // 真正判断能否读取要靠下面的 isReadableFile 检查。
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 2. 可读性前置校验，给出明确错误而不是让后续操作静默失败
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ImportError.accessDenied
        }

        // 3. 嗅探格式
        let format = FormatSniffer.sniff(url: url)
        guard format.isSupportedInCurrentMilestone else {
            throw ImportError.unsupportedFormat(url.pathExtension.lowercased())
        }

        // 4. 复制到沙盒
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

        // 5. 解析
        let parser = TextPublicationParser(fileStore: fileStore)
        let parsed: ParsedTextPublication
        do {
            parsed = try await parser.parse(
                url: destination,
                bookID: bookID,
                forcedEncoding: forcedEncoding
            )
        } catch {
            try? fileStore.deleteBook(bookID)
            throw ImportError.parseFailed(error.localizedDescription)
        }

        // 6. 写入数据库
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
        modelContext.insert(entity)

        do {
            try modelContext.save()
        } catch {
            try? fileStore.deleteBook(bookID)
            throw ImportError.parseFailed("保存书籍信息失败：\(error.localizedDescription)")
        }

        return ImportResult(
            bookID: bookID,
            title: parsed.metadata.title,
            chapterCount: parsed.chapters.count,
            detectedEncoding: parsed.detectedEncodingName
        )
    }

    /// 删除一本书（数据库 + 文件）。
    func deleteBook(_ entity: BookEntity) throws {
        let bookID = entity.id
        modelContext.delete(entity)
        try modelContext.save()
        try? fileStore.deleteBook(bookID)
    }
}
