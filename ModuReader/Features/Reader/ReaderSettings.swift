//
//  ReaderSettings.swift
//  ModuReader
//

import Foundation
import UIKit

/// 阅读模式。
enum ReadingMode: String, Codable, CaseIterable, Sendable {
    /// 分页阅读。
    case paged
    /// 纵向滚动阅读。
    case scroll

    var displayName: String {
        switch self {
        case .paged: "翻页"
        case .scroll: "滚动"
        }
    }
}

/// 翻页动画。
enum PageTurnAnimation: String, Codable, CaseIterable, Sendable {
    case slide
    case fade
    case none

    var displayName: String {
        switch self {
        case .slide: "滑动"
        case .fade: "淡入淡出"
        case .none: "瞬切"
        }
    }
}

/// 阅读设置。全部影响排版或渲染。
struct ReaderSettings: Codable, Equatable, Sendable {

    // MARK: 排版

    var fontFamily: ReaderFontFamily = .system
    /// 是否使用书籍自带字体（EPUB 内嵌）。为 true 时覆盖 `fontFamily`。
    var useBookFont: Bool = false
    /// 字号，范围 12...32。
    var fontSize: Double = 19
    /// 行距倍数，范围 1.2...2.4。
    var lineHeightMultiple: Double = 1.8
    /// 段间距，范围 0...32。
    var paragraphSpacing: Double = 8
    /// 首行缩进字符数，范围 0...4。
    var firstLineIndent: Int = 2
    /// 字距，范围 -0.5...2。
    var letterSpacing: Double = 0
    /// 左右内边距，范围 12...64。
    var horizontalPadding: Double = 24
    /// 上下内边距，范围 8...48。
    var verticalPadding: Double = 16

    // MARK: 主题

    var themeName: String = ReaderTheme.paper.name
    var followSystemAppearance: Bool = false
    /// 自定义强调色（`#RRGGBB`）。nil 表示使用主题自带的强调色。
    ///
    /// 声明为可选，旧的设置数据缺少这个键时也能解码。
    var accentHex: String? = nil

    // MARK: 阅读模式

    var readingMode: ReadingMode = .paged

    // MARK: 翻页

    var pageTurnAnimation: PageTurnAnimation = .slide
    /// 点击左右区域翻页的宽度占比，范围 0.15...0.35。
    var tapZoneRatio: Double = 0.25

    // MARK: 系统

    var keepScreenOn: Bool = true
    var showProgressInChrome: Bool = true

    // MARK: - Derived

    var theme: ReaderTheme {
        ReaderTheme.named(themeName)
    }

    /// 默认强调色（系统蓝）。主题自带的棕色只用于主题卡片装饰。
    static let defaultAccent = RGBColor(0.0, 0.478, 1.0)

    /// 当前强调色：自定义优先，否则用默认强调色。
    var accent: RGBColor {
        accentHex.flatMap { RGBColor(hex: $0) } ?? Self.defaultAccent
    }

    /// 构建排版指纹。
    ///
    /// - Parameter contentSize: 正文区域尺寸（已扣除安全区与工具栏）。
    func typographyProfile(contentSize: CGSize) -> TypographyProfile {
        TypographyProfile(
            fontFamily: fontFamily,
            fontSize: CGFloat(fontSize),
            lineHeightMultiple: CGFloat(lineHeightMultiple),
            paragraphSpacing: CGFloat(paragraphSpacing),
            firstLineIndent: firstLineIndent,
            letterSpacing: CGFloat(letterSpacing),
            contentWidth: contentSize.width - CGFloat(horizontalPadding) * 2,
            contentHeight: contentSize.height - CGFloat(verticalPadding) * 2
        )
    }

    /// 正文属性字典。
    func textAttributes(theme: ReaderTheme) -> [NSAttributedString.Key: Any] {
        typographyProfile(contentSize: CGSize(width: 1000, height: 1000))
            .attributes(textColor: theme.uiTextColor)
    }
}
