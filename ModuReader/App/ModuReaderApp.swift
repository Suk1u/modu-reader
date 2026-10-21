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
