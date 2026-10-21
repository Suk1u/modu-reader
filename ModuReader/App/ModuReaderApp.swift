//
//  ModuReaderApp.swift
//  ModuReader
//

import SwiftUI
import SwiftData

@main
struct ModuReaderApp: App {

    /// 处理系统通过文档类型打开本 App 的入口。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: ModelContainer
    private let appContainer: AppContainer

    init() {
        let container = ModuModelContainer.make()
        self.container = container
        self.appContainer = AppContainer(modelContainer: container)

        // 记录 App 启动方式，便于排查「共享面板打开无反应」。
        // - 若日志里没有 "AppDelegate: didFinishLaunching"，说明 AppDelegate
        //   没有被 SwiftUI 挂载（@UIApplicationDelegateAdaptor 失效）。
        // - 若只有 didFinishLaunching 而没有 "open url"，说明系统没有把文件
        //   交给本 App（CFBundleDocumentTypes 未被系统识别，通常发生在
        //   未签名 IPA 被侧载工具重签后）。
        Diagnostics.log("App: init, sceneManifest=\(Bundle.main.infoDictionary?["UIApplicationSceneManifest"] != nil)")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appContainer)
                .modelContainer(container)
                .preferredColorScheme(appContainer.appearanceOverride)
        }
    }
}

/// 根视图。承载 Tab 导航。
struct RootView: View {
    @Environment(AppContainer.self) private var appContainer

    var body: some View {
        @Bindable var appContainer = appContainer

        TabView(selection: $appContainer.selectedTab) {
            Tab("书架", systemImage: "books.vertical.fill", value: AppContainer.Tab.library) {
                LibraryView()
            }

            Tab("设置", systemImage: "gearshape.fill", value: AppContainer.Tab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(ReaderTheme.paper.accentColor)
    }
}
