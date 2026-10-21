//
//  TypographyProfile.swift
//  ModuReader
//
//  排版指纹。分页缓存的键，也是判断「是否需要重新分页」的依据。
//

import Foundation
import UIKit

/// 阅读字体族。
enum ReaderFontFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case serif
    case songti
    case kaiti
    case fangsong
    case pingfang

    var displayName: String {
        switch self {
        case .system: "系统"
        case .serif: "衬线"
        case .songti: "宋体"
        case .kaiti: "楷体"
        case .fangsong: "仿宋"
        case .pingfang: "苹方"
        }
    }

    /// 实际字体名。找不到时回退到系统字体。
    var postScriptName: String? {
        switch self {
        case .system: nil
        case .serif: "TimesNewRomanPSMT"
        case .songti: "Songti SC"
        case .kaiti: "Kaiti SC"
        case .fangsong: "STFangsong"
        case .pingfang: "PingFang SC"
        }
    }

    /// 构建字体。优先使用指定字体，失败则回退系统字体。
    ///
    /// - Parameters:
    ///   - size: 字号（pt）。
    ///   - weight: 字重。
    func font(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        if let name = postScriptName, let custom = UIFont(name: name, size: size) {
            // 自定义字体不支持动态字重时，直接返回
            return custom
        }
        return UIFont.systemFont(ofSize: size, weight: weight)
    }
}

/// 排版指纹。
///
/// 任何影响分页结果的参数都必须进入此结构。否则换字号后缓存会命中错误的分页。
struct TypographyProfile: Hashable, Sendable {
    var fontFamily: ReaderFontFamily
    var fontSize: CGFloat
    var lineHeightMultiple: CGFloat
    var paragraphSpacing: CGFloat
    var firstLineIndent: Int
    var letterSpacing: CGFloat
    /// 正文可用宽度（已扣除左右内边距），取整到 0.5pt。
    var contentWidth: CGFloat
    /// 正文可用高度（已扣除上下内边距），取整到 0.5pt。
    var contentHeight: CGFloat
    var language: String

    init(
        fontFamily: ReaderFontFamily = .system,
        fontSize: CGFloat = 19,
        lineHeightMultiple: CGFloat = 1.8,
        paragraphSpacing: CGFloat = 8,
        firstLineIndent: Int = 2,
        letterSpacing: CGFloat = 0,
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        language: String = "zh"
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeightMultiple = lineHeightMultiple
        self.paragraphSpacing = paragraphSpacing
        self.firstLineIndent = firstLineIndent
        self.letterSpacing = letterSpacing
        self.contentWidth = TypographyProfile.round(contentWidth)
        self.contentHeight = TypographyProfile.round(contentHeight)
        self.language = language
    }

    /// 稳定的缓存键。
    var cacheKey: String {
        let parts: [String] = [
            fontFamily.rawValue,
            String(format: "%.1f", fontSize),
            String(format: "%.2f", lineHeightMultiple),
            String(format: "%.1f", paragraphSpacing),
            "\(firstLineIndent)",
            String(format: "%.2f", letterSpacing),
            String(format: "%.1f", contentWidth),
            String(format: "%.1f", contentHeight),
            language,
        ]
        return parts.joined(separator: "|")
    }

    /// 判断两个指纹是否会导致分页结果变化。
    ///
    /// 仅颜色 / 主题变化**不应**触发重新分页。
    func requiresRepagination(comparedTo other: TypographyProfile) -> Bool {
        cacheKey != other.cacheKey
    }

    /// 构建段落样式。
    func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphSpacing
        style.alignment = .justified
        style.lineBreakMode = .byWordWrapping
        // 中文避头尾：允许标点悬挂
        style.lineBreakStrategy = .pushOut
        if firstLineIndent > 0 {
            let indent = fontSize * CGFloat(firstLineIndent)
            style.firstLineHeadIndent = indent
            style.headIndent = 0
        }
        return style
    }

    /// 构建正文属性字典。
    ///
    /// - Parameter textColor: 文字颜色。用 `UIColor` 而非 SwiftUI `Color`，
    ///   因为属性字典最终要交给 TextKit。
    func attributes(textColor: UIColor) -> [NSAttributedString.Key: Any] {
        let font = fontFamily.font(size: fontSize)
        return [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle(),
            .kern: letterSpacing,
        ]
    }

    /// 构建正文属性字典（RGB 分量版，可跨队列传递）。
    func attributes(textColor: RGBColor) -> [NSAttributedString.Key: Any] {
        attributes(textColor: textColor.uiColor)
    }

    private static func round(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
