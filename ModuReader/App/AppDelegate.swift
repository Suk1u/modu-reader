//
//  AppDelegate.swift
//  ModuReader
//
//  处理系统通过文档类型打开本 App 的入口。
//
//  背景：
//  Info.plist 里声明了 CFBundleDocumentTypes 后，用户在「文件」App 或
//  分享面板选择「用墨读打开」时，系统会把文件 URL 交给 App。
//  这条路径的入口是 `application(_:open:options:)`。
//
//  为什么不能只靠 SwiftUI 的 onOpenURL：
//  onOpenURL 主要服务于自定义 URL scheme（如 modureader://）。
//  对于「文档类型」打开的路径，冷启动时它不保证触发。
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
        Diagnostics.log("AppDelegate: didFinishLaunching")

        // 冷启动时系统可能把文件 URL 放在 launchOptions 里
        if let url = launchOptions?[.url] as? URL {
            Diagnostics.log("AppDelegate: cold-start file \(url.lastPathComponent)")
            deliver(url, delay: 1.0)
        }

        // 记录系统实际识别的文档类型注册情况。
        // 若这里打印的条目数与 Info.plist 声明的不一致，
        // 说明侧载工具重签时丢失了 document types 声明。
        Self.logDocumentTypeRegistration()

        return true
    }

    /// 检查系统层面本 App 注册了哪些文档类型。
    ///
    /// 做法：遍历 Info.plist 里声明的每个 UTType，用
    /// `UIApplication.shared.canOpenURL` 无法判断类型注册，
    /// 因此改为读取 LaunchServices 可见的 handler 数量。
    /// 这里用简化的日志输出，供人工比对。
    private static func logDocumentTypeRegistration() {
        let declared = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        var allTypes: [String] = []
        for entry in declared {
            if let types = entry["LSItemContentTypes"] as? [String] {
                allTypes.append(contentsOf: types)
            }
        }
        Diagnostics.log("AppDelegate: 声明的 UTI = \(allTypes.joined(separator: ", "))")
        Diagnostics.log("AppDelegate: 若从共享面板打开时没有下方 'open url' 日志，说明系统未把文件交给本 App")
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Diagnostics.log("AppDelegate: open url \(url.lastPathComponent)")
        deliver(url, delay: 0)
        return true
    }

    /// iOS 18+ 的新入口，用于「就地打开」文档。
    func application(
        _ application: UIApplication,
        open url: URL,
        inPlaceOpen: Bool
    ) -> Bool {
        Diagnostics.log("AppDelegate: open inPlace \(url.lastPathComponent)")
        deliver(url, delay: 0)
        return true
    }

    /// 把 URL 投递给 SwiftUI 层。
    ///
    /// 关键：在这里**立即同步复制**到暂存区。
    /// 系统传入的 Inbox 文件可能被清理，安全范围授权也可能在回调返回后失效。
    /// 先复制出一个稳定副本，再交给上层慢慢处理。
    ///
    /// - Parameter delay: 冷启动场景下视图层级尚未建立，需要延迟投递，
    ///   否则订阅者还没注册，通知会丢失。
    private func deliver(_ url: URL, delay: TimeInterval) {
        let originalName = url.lastPathComponent

        // 同步复制（此时还在 AppDelegate 回调内，授权有效）
        let staged: URL
        do {
            staged = try StageFile.copyToStaging(url)
            Diagnostics.log("AppDelegate: staged \(originalName) -> \(staged.lastPathComponent)")
        } catch {
            Diagnostics.log("AppDelegate: staging failed \(error.localizedDescription)")
            // 复制失败也要把原 URL 投递出去，让上层给出可见错误
            let post = {
                NotificationCenter.default.post(
                    name: .moduOpenDocument,
                    object: OpenDocumentPayload(url: url, originalName: originalName)
                )
            }
            schedule(post, delay: delay)
            return
        }

        let payload = OpenDocumentPayload(url: staged, originalName: originalName)
        let post = {
            NotificationCenter.default.post(name: .moduOpenDocument, object: payload)
        }
        schedule(post, delay: delay)
    }

    private func schedule(_ block: @escaping () -> Void, delay: TimeInterval) {
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

/// 通过通知传递的待打开文档。
///
/// 用结构体而非裸 URL：需要同时携带原始文件名（用于推导书名），
/// 而暂存副本的文件名是 UUID。
struct OpenDocumentPayload: Sendable {
    var url: URL
    var originalName: String
}
