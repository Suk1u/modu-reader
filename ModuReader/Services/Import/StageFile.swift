//
//  StageFile.swift
//  ModuReader
//
//  把外部 URL 同步复制到沙盒暂存区。
//
//  为什么需要这一步：
//  `fileImporter` / `UIDocumentPickerViewController` 返回的 URL 带安全范围授权，
//  该授权与 picker 的生命周期绑定。回调发生在 picker 关闭之后，
//  若在异步任务中才去读取原 URL，授权可能已失效，
//  表现为「文件读不到」且错误被 SwiftUI 静默丢弃。
//
//  因此必须在回调内**同步**完成复制，之后再慢慢处理暂存副本。
//

import Foundation

enum StageFile {

    /// 暂存目录。每次导入的文件都放在这里，处理完由调用方删除。
    static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ModuStaging", isDirectory: true)
    }

    /// 同步复制外部文件到暂存目录。
    ///
    /// - Parameter url: picker 返回的 URL（可能带安全范围授权）。
    /// - Returns: 暂存副本的 URL。调用方负责在使用后删除。
    /// - Throws: 复制失败时抛出，附带具体原因。
    static func copyToStaging(_ url: URL) throws -> URL {
        Diagnostics.log("StageFile: start \(url.lastPathComponent)")

        // 安全范围：asCopy=true 的 URL 已在沙盒内，返回 false 属正常。
        // 仍然调用一次，兼容 openURL 传入的外部 URL。
        let scoped = url.startAccessingSecurityScopedResource()
        Diagnostics.log("StageFile: securityScope=\(scoped)")
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 先确认可读。iCloud 占位符在这里会触发同步下载，
        // 因此可能耗时数秒 —— 这是不可避免的，用户选完文件本就期望等待。
        let readable = FileManager.default.isReadableFile(atPath: url.path)
        Diagnostics.log("StageFile: readable=\(readable)")
        guard readable else {
            throw StageError.notReadable(url.lastPathComponent)
        }

        let directory = stagingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = url.pathExtension.lowercased()
        let stagedName = ext.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(stagedName)

        // 目标已存在（UUID 冲突，几乎不可能）时先删除
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            Diagnostics.log("StageFile: copy failed \(error.localizedDescription)")
            throw StageError.copyFailed(
                url.lastPathComponent,
                error.localizedDescription
            )
        }

        // 校验复制结果：大小为 0 说明源文件是未下载的 iCloud 占位符
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        Diagnostics.log("StageFile: copied size=\(size)")
        if size == 0 {
            try? FileManager.default.removeItem(at: destination)
            throw StageError.emptyFile(url.lastPathComponent)
        }

        return destination
    }

    /// 删除暂存文件。导入结束后必须调用。
    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 清理整个暂存目录（App 启动时可调用一次）。
    static func purgeAll() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    // MARK: - Errors

    enum StageError: LocalizedError {
        case notReadable(String)
        case copyFailed(String, String)
        case emptyFile(String)

        var errorDescription: String? {
            switch self {
            case .notReadable(let name):
                "无法读取「\(name)」。若文件在 iCloud 中，请先在「文件」App 里下载到本地。"
            case .copyFailed(let name, let reason):
                "复制「\(name)」失败：\(reason)"
            case .emptyFile(let name):
                "「\(name)」是空文件，或尚未从 iCloud 下载完成。"
            }
        }
    }
}
