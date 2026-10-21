//
//  RenderEngine.swift
//  ModuReader
//
//  渲染引擎统一协议。所有引擎只依赖 UIKit，不依赖 SwiftUI。
//

import Foundation
import UIKit

/// 引擎类型。
enum EngineKind: String, Sendable {
    case textKit
    case webKit
    case imagePaged
    case imageWebtoon
    case pdf
}

/// 用户在阅读区的手势结果。
enum ReaderInteraction: Sendable {
    case tapCenter
    case tapLeft
    case tapRight
    case selectionChanged
}

/// 渲染引擎。
///
/// 实现约束：
/// - 所有实现都是 `@MainActor`，UI 操作必须在主线程。
/// - 耗时工作（分页、解码）由实现内部派发到后台，但不得把 TextKit 对象跨队列传递。
@MainActor
protocol RenderEngine: AnyObject {

    var kind: EngineKind { get }

    /// 当前可视位置的 Locator。
    var currentLocator: Locator { get }

    /// 全书进度 0...1。
    var totalProgression: Double { get }

    /// 位置变化回调（节流后上报）。
    var onLocatorChange: ((Locator) -> Void)? { get set }

    /// 用户交互回调。
    var onInteraction: ((ReaderInteraction) -> Void)? { get set }

    /// 加载书籍。
    func load(
        book: BookDescriptor,
        initialLocator: Locator?,
        settings: ReaderSettings
    ) async throws

    /// 应用新的阅读设置。
    func apply(settings: ReaderSettings) async

    /// 跳转到指定位置。
    func go(to locator: Locator, animated: Bool) async

    /// 下一页。返回 `false` 表示已到结尾。
    func nextPage() async -> Bool

    /// 上一页。返回 `false` 表示已到开头。
    func previousPage() async -> Bool

    /// 下一章。
    func nextChapter() async

    /// 上一章。
    func previousChapter() async

    /// 跳转到章节。
    func goToChapter(at index: Int) async

    /// 当前可见文本（无障碍 / 选中）。
    func visibleText() -> String?

    /// 章节列表（用于目录面板）。
    var chapters: [Chapter] { get }

    /// 当前章节序号。
    var currentChapterIndex: Int { get }
}
