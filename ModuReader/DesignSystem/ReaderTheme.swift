//
//  ReaderTheme.swift
//  ModuReader
//
//  阅读主题。颜色以语义名定义，正文对比度满足 WCAG AA。
//
//  为什么存 RGB 分量而不是直接存 Color / UIColor：
//  分页在后台队列执行，需要把文字颜色传过去。UIColor 与 SwiftUI Color
//  的 Sendable 保证随 SDK 版本变化，而纯 RGB 分量是无争议的 Sendable 值类型。
//

import SwiftUI
import UIKit

/// 与框架无关的 RGB 颜色。`Sendable`，可跨队列传递。
struct RGBColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// `#RRGGBB` 形式，供 Readium 的 `Color(hex:)` 使用。
    var hexString: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// 阅读主题。
///
/// 约束：
/// - 正文与背景对比度 ≥ 4.5:1。
/// - 颜色是语义定义，不在视图里散落 hex。
/// - 夜间主题提供纯黑选项，适配 OLED。
struct ReaderTheme: Identifiable, Hashable, Sendable {
    let name: String
    let displayName: String
    let background: RGBColor
    let text: RGBColor
    let secondaryText: RGBColor
    /// 功能层强调色，克制使用。
    let accent: RGBColor
    /// 是否为深色主题。
    let isDark: Bool

    var id: String { name }

    var backgroundColor: Color { background.color }
    var textColor: Color { text.color }
    var secondaryTextColor: Color { secondaryText.color }
    var accentColor: Color { accent.color }

    var uiTextColor: UIColor { text.uiColor }
    var uiBackgroundColor: UIColor { background.uiColor }

    // MARK: - Built-in

    static let paper = ReaderTheme(
        name: "paper",
        displayName: "纸白",
        background: RGBColor(0.969, 0.953, 0.910),
        text: RGBColor(0.169, 0.169, 0.169),
        secondaryText: RGBColor(0.42, 0.40, 0.36),
        accent: RGBColor(0.62, 0.42, 0.20),
        isDark: false
    )

    static let night = ReaderTheme(
        name: "night",
        displayName: "夜间",
        background: RGBColor(0.071, 0.071, 0.071),
        text: RGBColor(0.784, 0.784, 0.784),
        secondaryText: RGBColor(0.52, 0.52, 0.52),
        accent: RGBColor(0.55, 0.62, 0.78),
        isDark: true
    )

    static let pureBlack = ReaderTheme(
        name: "pureBlack",
        displayName: "纯黑",
        background: RGBColor(0, 0, 0),
        text: RGBColor(0.69, 0.69, 0.69),
        secondaryText: RGBColor(0.45, 0.45, 0.45),
        accent: RGBColor(0.50, 0.58, 0.74),
        isDark: true
    )

    static let sepia = ReaderTheme(
        name: "sepia",
        displayName: "羊皮纸",
        background: RGBColor(0.941, 0.886, 0.784),
        text: RGBColor(0.227, 0.180, 0.122),
        secondaryText: RGBColor(0.44, 0.38, 0.30),
        accent: RGBColor(0.55, 0.36, 0.16),
        isDark: false
    )

    static let green = ReaderTheme(
        name: "green",
        displayName: "护眼",
        background: RGBColor(0.800, 0.910, 0.812),
        text: RGBColor(0.133, 0.188, 0.165),
        secondaryText: RGBColor(0.32, 0.40, 0.36),
        accent: RGBColor(0.20, 0.45, 0.32),
        isDark: false
    )

    /// 高对比黑白。OLED 下最省电，也最接近系统「原始」主题。
    static let original = ReaderTheme(
        name: "original",
        displayName: "原始",
        background: RGBColor(0, 0, 0),
        text: RGBColor(1, 1, 1),
        secondaryText: RGBColor(0.62, 0.62, 0.62),
        accent: RGBColor(0.04, 0.52, 1.0),
        isDark: true
    )

    /// 主题网格的排列顺序：三个浅色在前，三个深色在后。
    static let all: [ReaderTheme] = [.paper, .sepia, .green, .night, .pureBlack, .original]

    static func named(_ name: String) -> ReaderTheme {
        all.first { $0.name == name } ?? .paper
    }
}
