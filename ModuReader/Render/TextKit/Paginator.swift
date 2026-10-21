//
//  Paginator.swift
//  ModuReader
//
//  TextKit 2 分页器。
//
//  算法：按 fragment 累积高度，放不下时用行级 segment 细分。
//
//  为什么这样分层：
//  - NSTextLayoutFragment 是段落级缓存单元，`layoutFragmentFrame` 给出它在容器中的
//    精确矩形。整块放得下就直接累加，避免逐行枚举的开销。
//  - 当一个 fragment 放不下时，用 `enumerateTextSegments(in: type: .standard)`
//    逐行切。该 API 返回的 `NSTextRange` 是文档级绝对位置，语义明确，
//    不像 `NSTextLineFragment.characterRange` 那样存在坐标系歧义。
//

import Foundation
import UIKit

/// TextKit 2 分页器。
///
/// 线程约束：分页在调用方的串行队列上执行。内部创建的
/// `NSTextContentStorage` / `NSTextLayoutManager` **不得**跨队列共享。
/// 输出为 `PaginatedChapter`（`Sendable` 值类型）。
enum Paginator {

    /// 对一章文本分页。
    ///
    /// - Parameters:
    ///   - attributedText: 已应用排版属性的章节文本。
    ///   - profile: 排版指纹（决定可用尺寸）。
    ///   - chapterIndex: 章节序号。
    /// - Returns: 分页快照。
    static func paginate(
        attributedText: NSAttributedString,
        profile: TypographyProfile,
        chapterIndex: Int
    ) -> PaginatedChapter {
        let length = attributedText.length
        guard length > 0 else {
            return PaginatedChapter(
                chapterIndex: chapterIndex,
                characterCount: 0,
                slices: [PageSlice(range: NSRange(location: 0, length: 0), pageIndex: 0)]
            )
        }

        let contentSize = CGSize(
            width: max(1, profile.contentWidth),
            height: max(1, profile.contentHeight)
        )

        // 建立独立的 TextKit 2 栈（每章一次，不复用）
        let contentStorage = NSTextContentStorage()
        contentStorage.attributedString = attributedText

        let layoutManager = NSTextLayoutManager()
        layoutManager.usesFontLeading = true
        layoutManager.usesHyphenation = false

        let container = NSTextContainer(size: contentSize)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.textContainer = container

        contentStorage.addTextLayoutManager(layoutManager)

        // 强制完成布局，保证枚举到的 fragment 都有真实几何
        layoutManager.ensureLayout(for: contentStorage.documentRange)

        let slices = collectPageSlices(
            layoutManager: layoutManager,
            contentStorage: contentStorage,
            pageHeight: contentSize.height,
            totalLength: length
        )

        return PaginatedChapter(
            chapterIndex: chapterIndex,
            characterCount: length,
            slices: slices.isEmpty
                ? [PageSlice(range: NSRange(location: 0, length: length), pageIndex: 0)]
                : slices
        )
    }

    /// 对纯文本分页。
    ///
    /// 这是跨队列调用的入口：参数全部是 `Sendable` 值类型，
    /// `NSAttributedString` 在内部构造，不跨越队列边界。
    static func paginate(
        text: String,
        profile: TypographyProfile,
        textColor: RGBColor,
        chapterIndex: Int
    ) -> PaginatedChapter {
        let attributed = NSAttributedString(
            string: text,
            attributes: profile.attributes(textColor: textColor)
        )
        return paginate(
            attributedText: attributed,
            profile: profile,
            chapterIndex: chapterIndex
        )
    }

    // MARK: - Core

    /// 按 fragment / 行 segment 累积高度，切分为页。
    private static func collectPageSlices(
        layoutManager: NSTextLayoutManager,
        contentStorage: NSTextContentStorage,
        pageHeight: CGFloat,
        totalLength: Int
    ) -> [PageSlice] {
        var slices: [PageSlice] = []
        var pageStart = 0
        var accumulatedHeight: CGFloat = 0
        var pageIndex = 0
        /// 当前页已覆盖到的字符位置。
        var consumedUpTo = 0

        layoutManager.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentHeight = fragment.layoutFragmentFrame.height
            let fragmentRange = fragment.rangeInElement

            guard let range = Self.nsRange(
                for: fragmentRange,
                contentStorage: contentStorage,
                totalLength: totalLength
            ), range.length > 0 else {
                return true
            }

            // 情况 A：整块放得下
            if accumulatedHeight + fragmentHeight <= pageHeight {
                accumulatedHeight += fragmentHeight
                consumedUpTo = range.location + range.length
                return true
            }

            // 情况 B：放不下，逐行细分
            let didFit = Self.consumeLineByLine(
                fragmentRange: fragmentRange,
                layoutManager: layoutManager,
                contentStorage: contentStorage,
                pageHeight: pageHeight,
                totalLength: totalLength,
                slices: &slices,
                pageStart: &pageStart,
                accumulatedHeight: &accumulatedHeight,
                pageIndex: &pageIndex,
                consumedUpTo: &consumedUpTo
            )

            // 情况 C：拿不到行信息（极端情况），整块单独成页
            if !didFit {
                if consumedUpTo > pageStart {
                    slices.append(
                        PageSlice(
                            range: NSRange(location: pageStart, length: consumedUpTo - pageStart),
                            pageIndex: pageIndex
                        )
                    )
                    pageIndex += 1
                }
                pageStart = range.location
                accumulatedHeight = fragmentHeight
                consumedUpTo = range.location + range.length
            }

            return true
        }

        // 收尾：剩余文本作为最后一页
        if pageStart < totalLength {
            slices.append(
                PageSlice(
                    range: NSRange(location: pageStart, length: totalLength - pageStart),
                    pageIndex: pageIndex
                )
            )
        }

        return slices
    }

    /// 逐行消费一个放不下的 fragment。
    ///
    /// - Returns: `true` 表示成功按行处理；`false` 表示该 fragment 没有可用的行 segment。
    private static func consumeLineByLine(
        fragmentRange: NSTextRange,
        layoutManager: NSTextLayoutManager,
        contentStorage: NSTextContentStorage,
        pageHeight: CGFloat,
        totalLength: Int,
        slices: inout [PageSlice],
        pageStart: inout Int,
        accumulatedHeight: inout CGFloat,
        pageIndex: inout Int,
        consumedUpTo: inout Int
    ) -> Bool {
        var handledAnyLine = false

        layoutManager.enumerateTextSegments(
            in: fragmentRange,
            type: .standard,
            options: []
        ) { segmentRange, segmentFrame, _, _ in
            guard let segmentRange,
                  let lineRange = Self.nsRange(
                    for: segmentRange,
                    contentStorage: contentStorage,
                    totalLength: totalLength
                  ),
                  lineRange.length > 0 else {
                return true
            }

            let lineHeight = segmentFrame.height
            guard lineHeight > 0 else { return true }

            handledAnyLine = true

            // 这一行放不下，且当前页已有内容 → 结束当前页
            if accumulatedHeight + lineHeight > pageHeight, consumedUpTo > pageStart {
                slices.append(
                    PageSlice(
                        range: NSRange(location: pageStart, length: consumedUpTo - pageStart),
                        pageIndex: pageIndex
                    )
                )
                pageIndex += 1
                pageStart = consumedUpTo
                accumulatedHeight = 0
            }

            // 单行超过整页：单独成页，防止死循环
            if lineHeight > pageHeight {
                slices.append(
                    PageSlice(
                        range: NSRange(location: lineRange.location, length: lineRange.length),
                        pageIndex: pageIndex
                    )
                )
                pageIndex += 1
                pageStart = lineRange.location + lineRange.length
                accumulatedHeight = 0
                consumedUpTo = pageStart
                return true
            }

            accumulatedHeight += lineHeight
            consumedUpTo = lineRange.location + lineRange.length
            return true
        }

        return handledAnyLine
    }

    /// 把 `NSTextRange` 转换为源字符串中的 `NSRange`。
    private static func nsRange(
        for textRange: NSTextRange,
        contentStorage: NSTextContentStorage,
        totalLength: Int
    ) -> NSRange? {
        let documentStart = contentStorage.documentRange.location
        let start = contentStorage.offset(from: documentStart, to: textRange.location)
        let end = contentStorage.offset(from: documentStart, to: textRange.endLocation)
        guard start >= 0, end >= start, end <= totalLength else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
