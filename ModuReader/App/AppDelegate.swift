//
//  AppDelegate.swift
//  ModuReader
//
//  处理系统通过文档类型打开本 App 的入口。
//
//  为什么需要 AppDelegate：
//  SwiftUI 的 `onOpenURL` 在「App 冷启动时由系统打开文档」这条路径上
//  不一定被调用 —— 尤其是 `UIApplicationSceneManifest` 存在时，
//  系统走的是 `application(_:open:options:)` / `scene(_:openURLContexts:)`。
//  这里同时实现两处，并统一转发到 SwiftUI 层。
//

import UIKit

extension Notification.Name {
    /// AppDelegate 收到待打开文件时发出。
    static let moduOpenDocument = Notification.Name("com.modu.reader.openDocument")
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 冷启动时系统可能把文件 URL 放在 launchOptions 里
        if let url = launchOptions?[.url] as? URL {
            post(url)
        }
        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        post(url)
        return true
    }

    /// 从另一个 App 分享/打开文件。
    func application(
        _ application: UIApplication,
        open url: URL,
        inPlaceOpen: Bool
    ) -> Bool {
        post(url)
        return true
    }

    private func post(_ url: URL) {
        // 用异步投递，确保 SwiftUI 视图层级已经建立、订阅者已注册
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .moduOpenDocument, object: url)
        }
    }
}
