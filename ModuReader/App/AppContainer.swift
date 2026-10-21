//
//  AppContainer.swift
//  ModuReader
//
//  依赖注入根。全应用共享的服务与全局 UI 状态。
//

import Foundation
import SwiftUI
import SwiftData

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
