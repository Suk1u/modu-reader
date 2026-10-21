//
//  Locator.swift
//  ModuReader
//
//  全书唯一位置真相。任何阅读位置都必须能表达为 Locator。
//

import Foundation

/// 全书唯一位置真相。
///
/// 设计要点：
/// - `locations.charOffset` 是文字引擎的主定位（UTF-16 code unit）。
/// - `text` 用于跨排版、跨设备的模糊重定位。
/// - 禁止用「第几页」作为持久化进度——页码随字号、屏幕尺寸变化。
struct Locator: Codable, Hashable, Sendable {
    /// 指向 Resource.href。
    var href: String
    var mediaType: String
    var locations: Locations
    /// 用于模糊重定位（换排版 / 换源后仍能找回）。
    var text: TextQuote?

    init(
        href: String,
        mediaType: String = "text/plain",
        locations: Locations = Locations(),
        text: TextQuote? = nil
    ) {
        self.href = href
        self.mediaType = mediaType
        self.locations = locations
        self.text = text
    }
}

struct Locations: Codable, Hashable, Sendable {
    /// 资源内进度 0...1（用于无字符偏移能力的引擎，如 PDF）。
    var progression: Double?
    /// 全书进度 0...1（用于进度条、统计）。
    var totalProgression: Double?
    /// 资源内字符偏移（UTF-16 code unit），文字引擎的主定位。
    var charOffset: Int?
    /// 资源内页码（图像引擎）。
    var page: Int?
    /// 精确定位片段（EPUB CFI 片段 / 图像区域）。
    var fragments: [String]?

    init(
        progression: Double? = nil,
        totalProgression: Double? = nil,
        charOffset: Int? = nil,
        page: Int? = nil,
        fragments: [String]? = nil
    ) {
        self.progression = progression
        self.totalProgression = totalProgression
        self.charOffset = charOffset
        self.page = page
        self.fragments = fragments
    }
}

/// 位置附近的文本引用，用于模糊重定位。
struct TextQuote: Codable, Hashable, Sendable {
    /// 目标前约 30 字。
    var before: String?
    /// 目标本身。
    var highlight: String
    /// 目标后约 30 字。
    var after: String?

    init(before: String? = nil, highlight: String, after: String? = nil) {
        self.before = before
        self.highlight = highlight
        self.after = after
    }

    /// 从一段文本的指定偏移处截取引用。
    static func extract(from text: String, offset: Int, radius: Int = 30) -> TextQuote {
        let ns = text as NSString
        let safeOffset = max(0, min(offset, ns.length))
        let start = max(0, safeOffset - radius)
        let end = min(ns.length, safeOffset + radius)
        let highlightLength = min(radius, ns.length - safeOffset)

        let before = start < safeOffset ? ns.substring(with: NSRange(location: start, length: safeOffset - start)) : nil
        let highlight = ns.substring(with: NSRange(location: safeOffset, length: max(0, highlightLength)))
        let after = end > safeOffset + highlightLength
            ? ns.substring(with: NSRange(location: safeOffset + highlightLength, length: end - safeOffset - highlightLength))
            : nil

        return TextQuote(before: before, highlight: highlight, after: after)
    }
}
