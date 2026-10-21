//
//  InboxScanner.swift
//  ModuReader
//
//  扫描 Documents/Inbox 里由系统投递的文件。
//
//  为什么需要它：
//  当 App 声明了 CFBundleDocumentTypes 且开启 UIFileSharingEnabled 时，
//  iOS 会把「共享到本 App」的文件**复制到 Documents/Inbox/**，
//  而不是通过 URL 回调交给 App。
//
//  实测 iOS 27.2 上，共享面板打开文件时：
//  - application(_:open:options:) 不被调用（scene 生命周期）
//  - scene(_:openURLContexts:) / onOpenURL 也不触发
//  - 但文件确实出现在 Documents/Inbox/
//
//  因此扫描 Inbox 是这条路径上唯一可靠的入口。
//

import Foundation

enum InboxScanner {

    /// 待导入的文件。
    struct InboxFile: Sendable {
        var url: URL
        var originalName: String
    }

    /// 扫描 Inbox 目录。
    ///
    /// - Returns: 找到的文件，按修改时间升序（先来的先处理）。
    static func scan() -> [InboxFile] {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return []
        }

        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        guard FileManager.default.fileExists(atPath: inbox.path) else {
            return []
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [InboxFile] = []
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            // 跳过系统临时文件
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), !name.hasSuffix(".tmp") else { continue }

            files.append(InboxFile(url: url, originalName: name))
        }

        return files.sorted {
            let a = (try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? $1.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a < b
        }
    }

    /// 把 Inbox 文件移出到暂存区，避免重复导入。
    ///
    /// 用移动而非复制：Inbox 是系统托管目录，处理完必须清理，
    /// 否则每次启动都会重新扫到同一个文件。
    static func take(_ file: InboxFile) throws -> URL {
        let staged = try StageFile.copyToStaging(file.url)
        try? FileManager.default.removeItem(at: file.url)
        return staged
    }

    /// 清空 Inbox（用户主动清理时用）。
    static func purge() {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.removeItem(at: inbox)
    }
}
