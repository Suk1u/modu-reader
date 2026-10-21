//
//  ImportPresenter.swift
//  ModuReader
//
//  直接用 UIKit 呈现文档选择器。
//
//  为什么不走 SwiftUI 的 .sheet / .fileImporter：
//  两者都依赖 SwiftUI 的呈现协调器。在 iOS 26 + NavigationStack + searchable
//  的组合下，出现过 sheet 不呈现、picker 回调不触发的现象，
//  且失败时没有任何可观测信号（既不报错也不回调）。
//
//  这里直接拿 topmost UIViewController 调 present，绕开整个 SwiftUI 呈现层。
//

import UIKit
import UniformTypeIdentifiers

@MainActor
enum ImportPresenter {

    /// 呈现文档选择器。
    ///
    /// - Parameters:
    ///   - onPick: 选中文件后的回调。URL 由系统复制到 App 沙盒（asCopy: true）。
    ///   - onCancel: 取消回调。
    static func present(
        onPick: @escaping ([URL]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard let host = topmostViewController() else {
            Diagnostics.log("ImportPresenter: no host view controller")
            return
        }

        Diagnostics.log("ImportPresenter: presenting from \(type(of: host))")

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: FormatSniffer.supportedContentTypes,
            asCopy: true
        )

        let coordinator = Coordinator(onPick: onPick, onCancel: onCancel)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true

        // 把 coordinator 挂到 picker 上，保证其生命周期覆盖整个呈现过程。
        // UIDocumentPickerViewController.delegate 是 weak，不额外持有会被立即释放。
        objc_setAssociatedObject(
            picker,
            &ImportPresenter.coordinatorKey,
            coordinator,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        host.present(picker, animated: true) {
            Diagnostics.log("ImportPresenter: picker presented")
        }
    }

    // MARK: - Host lookup

    /// 找到当前最上层的可呈现视图控制器。
    static func topmostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        // 优先取前台活跃场景
        let activeScene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first

        guard let window = activeScene?.windows.first(where: \.isKeyWindow)
                ?? activeScene?.windows.first else {
            return nil
        }

        var controller = window.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }

        // 处理 UINavigationController / UITabBarController 容器
        if let nav = controller as? UINavigationController {
            var top = nav.topViewController
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top ?? nav
        }
        if let tab = controller as? UITabBarController {
            return tab.selectedViewController ?? tab
        }

        return controller
    }

    // MARK: - Coordinator

    private static var coordinatorKey: UInt8 = 0

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            Diagnostics.log("ImportPresenter: didPick \(urls.count) file(s)")
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Diagnostics.log("ImportPresenter: cancelled")
            onCancel()
        }
    }
}
