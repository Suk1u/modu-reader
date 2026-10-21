//
//  AppContainer.swift
//  ModuReader
//
//  依赖注入根。全应用共享的服务与全局 UI 状态。
//

import Foundation
import SwiftUI
import SwiftData
import UIKit

/// 依赖注入根。
@Observable
@MainActor
final class AppContainer {

    enum Tab: Hashable {
        case library
        case settings
    }

    /// 当前选中的 Tab。
    var selectedTab: Tab = .library

    /// 外观覆盖（nil 表示跟随系统）。
    var appearanceOverride: ColorScheme?

    /// 文件存储。
    let fileStore: FileStore

    /// 模型容器。
    let modelContainer: ModelContainer

    /// 全局阅读设置（跨书共享排版，主题与进度按书存）。
    var globalSettings: ReaderSettings = ReaderSettings()

    /// 分页缓存。为 nil 时每次都重新分页（功能不受影响，只是变慢）。
    let pageCache: PageIndexCache?

    /// 待导入的外部文件。
    ///
    /// 由 `onOpenURL` / AppDelegate 写入，`LibraryView` 消费。
    /// 用队列而非单个值：用户可能在导入过程中再分享一个文件。
    var pendingImports: [OpenDocumentPayload] = []

    /// 消费一个待导入文件。返回 nil 表示队列为空。
    func dequeuePendingImport() -> OpenDocumentPayload? {
        guard !pendingImports.isEmpty else { return nil }
        return pendingImports.removeFirst()
    }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        do {
            self.fileStore = try FileStore()
        } catch {
            // FileStore 初始化失败意味着沙盒不可写，这是不可恢复的环境问题。
            // 用临时目录兜底，至少让界面可用。
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("ModuBooks", isDirectory: true)
            self.fileStore = (try? FileStore(rootURL: temp)) ?? FileStore.fallback
        }
        self.pageCache = try? PageIndexCache()

        Self.logStartupDiagnostics(fileStore: fileStore, pageCache: pageCache)

        // 在容器初始化时就订阅文件打开通知，不依赖任何视图存活。
        //
        // 为什么不在 RootView 里 onReceive：
        // 冷启动时 SwiftUI 的视图层级尚未建立，通知会丢失。
        // AppContainer 在 App.init 里创建，是最早的可靠订阅点。
        startObservingOpenDocuments()
        scanInbox()
    }

    /// 扫描 Documents/Inbox。
    ///
    /// 这是「共享面板打开文件」在 iOS 26+ 上唯一可靠的入口：
    /// 系统把文件复制到 Inbox，而不是通过 URL 回调交付。
    func scanInbox() {
        let files = InboxScanner.scan()
        guard !files.isEmpty else { return }

        Diagnostics.log("AppContainer: Inbox 发现 \(files.count) 个文件")
        for file in files {
            do {
                let staged = try InboxScanner.take(file)
                Diagnostics.log("AppContainer: Inbox 移出 \(file.originalName)")
                enqueue(OpenDocumentPayload(url: staged, originalName: file.originalName))
            } catch {
                Diagnostics.log("AppContainer: Inbox 处理失败 \(error.localizedDescription)")
            }
        }
    }

    /// 订阅文件打开通知。
    ///
    /// 用 `Task { @MainActor in ... }` 桥接，避免在闭包里调用
    /// `MainActor.assumeIsolated`（后者在非主线程触发会崩溃）。
    private func startObservingOpenDocuments() {
        let center = NotificationCenter.default
        openDocumentObserver = center.addObserver(
            forName: .moduOpenDocument,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let payload = notification.object as? OpenDocumentPayload else { return }
            Task { @MainActor [weak self] in
                self?.handleIncomingStagedFile(payload)
            }
        }
    }

    /// 通知观察者句柄。AppContainer 存活整个 App 生命周期，
    /// 无需显式移除；保留句柄是为了未来可能的重置场景。
    ///
    /// `@ObservationIgnored`：这不是 UI 状态，不参与观察，
    /// 否则每次赋值都会触发视图刷新。
    @ObservationIgnored private var openDocumentObserver: NSObjectProtocol?

    /// 启动自检。把关键环境写入诊断日志，便于用户反馈问题。
    private static func logStartupDiagnostics(
        fileStore: FileStore,
        pageCache: PageIndexCache?
    ) {
        Diagnostics.log("=== ModuReader 启动 ===")
        Diagnostics.log("版本: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
        Diagnostics.log("系统: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        Diagnostics.log("设备: \(UIDevice.current.model)")
        Diagnostics.log("书籍目录: \(fileStore.rootURL.path)")
        Diagnostics.log("分页缓存: \(pageCache == nil ? "不可用" : "就绪")")

        let documentTypes = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        Diagnostics.log("文档类型声明: \(documentTypes.count) 项")
        for type in documentTypes {
            let name = type["CFBundleTypeName"] as? String ?? "?"
            let types = type["LSItemContentTypes"] as? [String] ?? []
            Diagnostics.log("  - \(name): \(types.joined(separator: ", "))")
        }
    }

    /// 为当前 ModelContext 构建导入服务。
    func makeImportService(context: ModelContext) -> ImportService {
        ImportService(fileStore: fileStore, modelContext: context)
    }

    // MARK: - Incoming files

    /// 处理系统通过 onOpenURL 传入的文件。
    ///
    /// 在这里**同步**暂存：onOpenURL 回调期间安全范围授权仍有效。
    func handleIncomingFile(_ url: URL) {
        Diagnostics.log("AppContainer: handleIncomingFile \(url.lastPathComponent)")

        let originalName = url.lastPathComponent
        do {
            let staged = try StageFile.copyToStaging(url)
            Diagnostics.log("AppContainer: staged \(originalName)")
            enqueue(OpenDocumentPayload(url: staged, originalName: originalName))
        } catch {
            Diagnostics.log("AppContainer: staging failed \(error.localizedDescription)")
            // 暂存失败也入队，让 LibraryView 展示可见错误
            enqueue(OpenDocumentPayload(url: url, originalName: originalName))
        }
    }

    /// 处理 AppDelegate 已暂存好的文件。
    func handleIncomingStagedFile(_ payload: OpenDocumentPayload) {
        Diagnostics.log("AppContainer: handleIncomingStagedFile \(payload.originalName)")
        enqueue(payload)
    }

    private func enqueue(_ payload: OpenDocumentPayload) {
        pendingImports.append(payload)
        // 切到书架，让用户看到导入结果
        selectedTab = .library
    }
}

extension FileStore {
    /// 最后兜底：用系统临时目录。仅在沙盒完全不可写时使用。
    static var fallback: FileStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModuBooksFallback", isDirectory: true)
        // 该路径若仍失败，说明设备存储已不可用，此时任何文件操作都会失败，
        // 用 fatalError 暴露问题比静默出错更容易定位。
        do {
            return try FileStore(rootURL: url)
        } catch {
            fatalError("无法创建任何可写目录：\(error)")
        }
    }
}
