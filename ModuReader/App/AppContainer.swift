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
    }

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
