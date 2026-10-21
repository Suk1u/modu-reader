//
//  ChapterSplitter.swift
//  ModuReader
//
//  TXT 章节切分。切分结果必须与原文偏移严格对应，禁止重新拼接字符串。
//

import Foundation

/// TXT 章节切分器。
///
/// 规则（优先级从高到低）：
/// 1. `第X章 / 节 / 回 / 卷 / 集 / 部 / 篇 / 话`
/// 2. 序章 / 楔子 / 引子 / 前言 / 序言 / 后记 / 尾声 / 番外
/// 3. `Chapter N`
/// 4. `（N）` / `(N)`
/// 5. `N.` / `N、`（仅在候选章节数 ≥ 20 时启用，防数字列表误判）
///
/// 保护机制：
/// - 匹配到的章节数 < 3 → 视为无章节，整本作为单章。
/// - 单章超过 100,000 字 → 按段落边界二次切分虚拟块。
enum ChapterSplitter {

    /// 无章节时的单章标题。
    static let fallbackTitle = "正文"

    /// 单章字符上限，超过则二次分块。
    static let maxChapterCharacters = 100_000

    /// 数字列表规则的最小启用阈值。
    static let numericListMinChapters = 20

    /// 判定为「有章节」的最少章节数。
    static let minChaptersToTrust = 3

    /// 单章节标题允许出现在文件开头之前的字符数（BOM、空行等）。
    static let leadingWhitespaceTolerance = 4

    // MARK: - Public

    /// 切分文本为章节区间。
    ///
    /// - Parameter text: 已归一化换行的纯文本。
    /// - Returns: 章节区间数组，range 为原文本 UTF-16 偏移，首尾相接、覆盖全文。
    static func split(_ text: String) -> [ChapterRange] {
        let ns = text as NSString
        guard ns.length > 0 else {
            return [ChapterRange(title: fallbackTitle, range: NSRange(location: 0, length: 0))]
        }

        let primaryRegex = try? NSRegularExpression(
            pattern: primaryPattern,
            options: [.anchorsMatchLines]
        )
        let numericRegex = try? NSRegularExpression(
            pattern: numericListPattern,
            options: [.anchorsMatchLines]
        )

        // 第一轮：只收集主规则候选（含数字列表候选，但分开存）
        var primaryCandidates: [Candidate] = []
        var numericCandidates: [Candidate] = []

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, lineRange, _, _ in
            guard let line, !line.isEmpty else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 60 else { return }

            if matches(trimmed, regex: primaryRegex) {
                primaryCandidates.append(Candidate(title: trimmed, location: lineRange.location))
            } else if matches(trimmed, regex: numericRegex) {
                numericCandidates.append(Candidate(title: trimmed, location: lineRange.location))
            }
        }

        // 选择候选集：
        // - 主规则命中足够 → 用主规则
        // - 否则若数字列表候选 ≥ 20 → 用数字列表（典型如「1. 标题」式网文）
        // - 否则视为无章节
        //
        // 例外：即使只有一个章节标题，只要它出现在文件开头且全文很长，
        // 仍按章节处理（单章超长时会被 splitOversizedChapters 二次分块）。
        // 否则「一个标题 + 十几万字」的网文会被整本当单章，分页时一次性吃满内存。
        let candidates: [Candidate]
        if primaryCandidates.count >= minChaptersToTrust {
            candidates = primaryCandidates
        } else if numericCandidates.count >= numericListMinChapters {
            candidates = numericCandidates
        } else if let single = primaryCandidates.first,
                  single.location <= Self.leadingWhitespaceTolerance,
                  ns.length > maxChapterCharacters {
            candidates = [single]
        } else {
            return fallbackForWholeText(ns: ns)
        }

        // 首个候选不在文件开头时，前面内容作为「前言」章节
        var result: [ChapterRange] = []
        if let first = candidates.first, first.location > 0 {
            let prefixRange = NSRange(location: 0, length: first.location)
            let prefixText = ns.substring(with: prefixRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefixText.isEmpty {
                result.append(ChapterRange(title: "前言", range: prefixRange))
            }
        }

        for (index, candidate) in candidates.enumerated() {
            let start = candidate.location
            let end = index + 1 < candidates.count
                ? candidates[index + 1].location
                : ns.length
            let length = max(0, end - start)
            guard length > 0 else { continue }
            result.append(
                ChapterRange(
                    title: sanitizeTitle(candidate.title),
                    range: NSRange(location: start, length: length)
                )
            )
        }

        guard !result.isEmpty else {
            return fallbackForWholeText(ns: ns)
        }

        return splitOversizedChapters(result, ns: ns)
    }

    // MARK: - Patterns

    /// 主规则：整行匹配。
    ///
    /// 注意 `\\d` 在 Swift 多行字符串里会先被 Swift 转义一次，
    /// 因此实际传给 NSRegularExpression 的是 `\d`。
    ///
    /// 标题尾部用 `[^。！？；，、\\n]{0,30}` 而不是 `[^\\n]{0,40}`：
    /// 正文行通常以句号、逗号结尾，标题不会。这是区分两者的关键。
    private static let primaryPattern = """
    ^\\s*(?:第[零一二三四五六七八九十百千万两\\d]{1,10}[章节回卷集部篇话][^。！？；，、\\n]{0,30}|(?:序章|楔子|引子|前言|序言|后记|尾声|番外)[^。！？；，、\\n]{0,30}|[Cc]hapter\\s+\\d+[^。！？；，、\\n]{0,50}|[（(]\\d{1,4}[）)][^。！？；，、\\n]{0,30})\\s*$
    """

    /// 数字列表规则：`1. 标题` 或 `1、标题`。
    ///
    /// 同样排除正文标点结尾。
    private static let numericListPattern = """
    ^\\s*\\d{1,4}[.、]\\s*[^。！？；，、\\n]{0,30}$
    """

    // MARK: - Matching

    private static func matches(_ line: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else {
            return false
        }
        return match.range == range
    }

    // MARK: - Helpers

    private struct Candidate {
        var title: String
        var location: Int
    }

    private static func sanitizeTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: "\u{FEFF}", with: "")
        title = title.replacingOccurrences(of: "\u{200B}", with: "")
        title = title.replacingOccurrences(of: "\u{00A0}", with: " ")
        title = title.replacingOccurrences(of: "\u{3000}", with: " ")
        title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty {
            return fallbackTitle
        }
        return title
    }

    private static func fallbackForWholeText(ns: NSString) -> [ChapterRange] {
        let whole = NSRange(location: 0, length: ns.length)
        return splitOversizedChapters(
            [ChapterRange(title: fallbackTitle, range: whole)],
            ns: ns
        )
    }

    /// 把超长章节按段落边界切分为若干虚拟块。
    ///
    /// 虚拟块只用于分页性能，标题带「（续N）」后缀。
    private static func splitOversizedChapters(
        _ chapters: [ChapterRange],
        ns: NSString
    ) -> [ChapterRange] {
        var output: [ChapterRange] = []
        output.reserveCapacity(chapters.count)

        for chapter in chapters {
            guard chapter.range.length > maxChapterCharacters else {
                output.append(chapter)
                continue
            }

            var offset = chapter.range.location
            let end = chapter.range.location + chapter.range.length
            var pieceIndex = 0

            while offset < end {
                let remaining = end - offset
                if remaining <= maxChapterCharacters {
                    let title = pieceIndex == 0 ? chapter.title : "\(chapter.title)（续\(pieceIndex)）"
                    output.append(ChapterRange(title: title, range: NSRange(location: offset, length: remaining)))
                    break
                }

                // 在 maxChapterCharacters 附近寻找最近的换行，避免切断段落
                let windowStart = offset + maxChapterCharacters
                let searchLength = min(2000, end - windowStart)
                var cut = windowStart

                if searchLength > 0 {
                    let searchRange = NSRange(location: windowStart, length: searchLength)
                    let newlineRange = ns.range(of: "\n", options: [], range: searchRange)
                    if newlineRange.location != NSNotFound {
                        cut = newlineRange.location + 1
                    }
                }

                let length = cut - offset
                guard length > 0 else { break }

                let title = pieceIndex == 0 ? chapter.title : "\(chapter.title)（续\(pieceIndex)）"
                output.append(ChapterRange(title: title, range: NSRange(location: offset, length: length)))

                offset = cut
                pieceIndex += 1
            }
        }

        return output
    }
}
