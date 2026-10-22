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
    /// 书籍自带字体的 PostScript 名。非 nil 时优先于 `fontFamily`。
    var bookFontName: String?
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
        bookFontName: String? = nil,
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
        self.bookFontName = bookFontName
        self.fontSize = fontSize
        self.lineHeightMultiple = lineHeightMultiple
        self.paragraphSpacing = paragraphSpacing
        self.firstLineIndent = firstLineIndent
        self.letterSpacing = letterSpacing
        self.contentWidth = TypographyProfile.round(contentWidth)
        self.contentHeight = TypographyProfile.round(contentHeight)
        self.language = language
    }

    /// 文件名安全的缓存键哈希。
    ///
    /// `cacheKey` 含 `|` 与小数点，不能直接作文件名。
    /// 这里用 FNV-1a 32 位哈希：足够短、无依赖、跨平台稳定
    /// （不能用 `Hasher`，它每次进程启动的种子不同）。
    var cacheKeyHash: String {
        var hash: UInt32 = 2_166_136_261
        for byte in cacheKey.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    /// 稳定的缓存键。
    var cacheKey: String {
        let parts: [String] = [
            bookFontName ?? fontFamily.rawValue,
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

        // 用 .natural 而非 .justified：
        // .justified 会拉伸字间空白来对齐右边界，中文正文里会出现
        // 字距忽宽忽窄的「空洞」，阅读体验差。中文排版惯例是左对齐。
        style.alignment = .natural
        style.lineBreakMode = .byWordWrapping

        // 中文避头尾：标点不出现在行首，允许悬挂到边界外
        style.lineBreakStrategy = .pushOut

        // 首行缩进 2 字符，续行顶格 —— 中文排版标准做法
        if firstLineIndent > 0 {
            style.firstLineHeadIndent = fontSize * CGFloat(firstLineIndent)
        }
        style.headIndent = 0
        style.tailIndent = 0

        return style
    }

    /// 构建正文属性字典。
    ///
    /// - Parameter textColor: 文字颜色。用 `UIColor` 而非 SwiftUI `Color`，
    ///   因为属性字典最终要交给 TextKit。
    func attributes(textColor: UIColor) -> [NSAttributedString.Key: Any] {
        let font = resolvedFont()
        var attributes: [NSAttributedString.Key: Any] = [:]
        attributes[.font] = font
        attributes[.foregroundColor] = textColor
        attributes[.paragraphStyle] = paragraphStyle()
        if letterSpacing != 0 {
            attributes[.kern] = NSNumber(value: Double(letterSpacing))
        }
        return attributes
    }

    /// 构建正文属性字典（RGB 分量版，可跨队列传递）。
    func attributes(textColor: RGBColor) -> [NSAttributedString.Key: Any] {
        attributes(textColor: textColor.uiColor)
    }

    /// 解析最终使用的字体。
    ///
    /// 优先用书籍自带字体；找不到时回退到 `fontFamily`。
    func resolvedFont() -> UIFont {
        if let bookFontName, let custom = UIFont(name: bookFontName, size: fontSize) {
            return custom
        }
        return fontFamily.font(size: fontSize)
    }

    private static func round(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
