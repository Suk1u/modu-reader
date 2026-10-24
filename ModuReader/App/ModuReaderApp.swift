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
                // onOpenURL 必须挂在 Scene 的最外层。
                //
                // iOS 26+ 强制 scene 生命周期：即使 Info.plist 没有
                // UIApplicationSceneManifest，系统也会走 scene(_:openURLContexts:)，
                // 而 application(_:open:options:) 不会被调用。
                // SwiftUI 把它桥接成 onOpenURL，但只在「当前活跃的视图」上触发。
                // 挂在 LibraryView（TabView 的子视图）里时，如果 App 启动后
                // 还没切到书架 Tab，或视图尚未完成首帧，回调会被丢弃。
                .onOpenURL { url in
                    Diagnostics.log("RootView: onOpenURL \(url.lastPathComponent)")
                    appContainer.handleIncomingFile(url)
                }
        }
    }
}

/// 根视图。承载 Tab 导航。
struct RootView: View {
    @Environment(AppContainer.self) private var appContainer
    @Environment(\.scenePhase) private var scenePhase

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
        .tint(appContainer.globalSettings.accent.color)
        // 回到前台时重新扫描 Inbox。
        //
        // 共享面板打开文件时，App 可能已在后台运行：
        // 系统把文件放进 Documents/Inbox 后直接把 App 唤到前台，
        // 此过程不触发任何 URL 回调 —— 只能靠主动扫描。
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Diagnostics.log("RootView: scenePhase -> active")
            appContainer.scanInbox()
        }
    }
}
