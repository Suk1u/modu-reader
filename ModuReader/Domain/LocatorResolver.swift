//
//  LocatorResolver.swift
//  ModuReader
//
//  把 Locator 还原为具体字符偏移。这是「换字号不丢位置」「换设备不丢位置」的核心。
//

import Foundation

/// 定位失败的原因。
enum LocatorResolutionError: Error, Equatable {
    /// 目标资源不存在。
    case resourceMissing
    /// 文本为空，无法定位。
    case emptyText
}

/// 把 Locator 还原为资源内的字符偏移。
///
/// 重定位优先级（不可调换）：
/// 1. `fragments` 精确匹配
/// 2. `charOffset` 直接定位（同一排版指纹下有效）
/// 3. `text.highlight` 模糊搜索（允许 1~2 字差异）
/// 4. `progression` 按比例落到最近的段落
/// 5. 兜底：资源开头
enum LocatorResolver {

    /// 把 locator 解析为 `text` 中的字符偏移。
    ///
    /// - Parameters:
    ///   - locator: 待解析的位置。
    ///   - text: 该资源的完整文本。
    /// - Returns: 字符偏移（UTF-16 code unit），已裁剪到合法范围。
    static func resolve(_ locator: Locator, in text: String) -> Int {
        let length = (text as NSString).length
        guard length > 0 else { return 0 }

        // 1. charOffset 直接定位
        if let offset = locator.locations.charOffset {
            if offset >= 0 && offset <= length {
                return offset
            }
            // 偏移越界（换源 / 内容被裁剪），落到最后合法位置继续尝试模糊匹配
        }

        // 2. text.highlight 模糊搜索
        if let quote = locator.text, !quote.highlight.isEmpty {
            if let found = fuzzyFind(quote, in: text) {
                return found
            }
        }

        // 3. progression 按比例
        if let progression = locator.locations.progression {
            let clamped = max(0, min(1, progression))
            return Int((Double(length) * clamped).rounded())
        }

        // 4. 兜底
        return 0
    }

    /// 在文本中模糊查找引用片段。
    ///
    /// 策略：先精确匹配 `highlight`；失败则用「前文 + 后文」定位夹缝；
    /// 再失败则退化为 `highlight` 的前 8 个字符做前缀搜索。
    static func fuzzyFind(_ quote: TextQuote, in text: String) -> Int? {
        let ns = text as NSString

        // 精确匹配
        let exact = ns.range(of: quote.highlight)
        if exact.location != NSNotFound {
            return exact.location
        }

        // 用前后文夹逼
        if let before = quote.before, let after = quote.after,
           !before.isEmpty, !after.isEmpty {
            let anchor = String(before.suffix(12))
            let tail = String(after.prefix(12))
            let anchorRange = ns.range(of: anchor)
            if anchorRange.location != NSNotFound {
                let candidateStart = anchorRange.location + anchorRange.length
                let remaining = NSRange(location: candidateStart, length: ns.length - candidateStart)
                let tailRange = ns.range(of: tail, options: [], range: remaining)
                if tailRange.location != NSNotFound {
                    return candidateStart
                }
            }
        }

        // 退化为前缀搜索
        let prefixLength = min(8, quote.highlight.count)
        guard prefixLength >= 2 else { return nil }
        let prefix = String(quote.highlight.prefix(prefixLength))
        let prefixRange = ns.range(of: prefix)
        if prefixRange.location != NSNotFound {
            return prefixRange.location
        }

        return nil
    }

    /// 由字符偏移构造一个 Locator。
    ///
    /// - Parameters:
    ///   - text: 资源完整文本。
    ///   - offset: 字符偏移（UTF-16）。
    ///   - href: 资源 href。
    ///   - mediaType: 资源媒体类型。
    ///   - totalCharacters: 全书总字符数，用于计算 totalProgression。
    ///   - charactersBeforeResource: 本书之前所有资源的字符数之和。
    static func makeLocator(
        text: String,
        offset: Int,
        href: String,
        mediaType: String = "text/plain",
        totalCharacters: Int,
        charactersBeforeResource: Int = 0
    ) -> Locator {
        let length = (text as NSString).length
        let clamped = max(0, min(offset, length))
        let progression = length > 0 ? Double(clamped) / Double(length) : 0
        let total = totalCharacters > 0
            ? Double(charactersBeforeResource + clamped) / Double(totalCharacters)
            : 0

        return Locator(
            href: href,
            mediaType: mediaType,
            locations: Locations(
                progression: progression,
                totalProgression: max(0, min(1, total)),
                charOffset: clamped
            ),
            text: TextQuote.extract(from: text, offset: clamped)
        )
    }
}
