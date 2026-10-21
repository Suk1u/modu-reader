//
//  Paginator.swift
//  ModuReader
//
//  分页器。用 TextKit 2 的 NSTextLayoutManager 计算每页字符区间与纵向偏移。
//
//  为什么用 NSTextLayoutManager 而不是 CTFramesetter：
//  - 与渲染共用同一套排版引擎，分页边界与绘制结果**必然一致**
//    （CTFramesetter 与 TextKit 2 虽同源，但属性解释、段落间距处理有差异）
//  - 支持 NSTextAttachment，图片可以真正参与文字流排版
//  - 支持懒布局与增量失效，长章节性能更好
//  - 段落属性（首行缩进、段间距）由 TextKit 统一解释，切片渲染不会错位
//
//  实现要点：
//  容器高度设为极大值，让整章一次性排完（不分页），
//  然后枚举每行的绝对 Y 坐标，按页高切分。
//  这样「分页」只是对已完成的排版结果做区间划分，不会二次排版。
//

import Foundation
import UIKit

/// 分页器。
///
/// 纯函数，无状态，可在任意后台队列调用。
/// 输入输出均为值类型，TextKit 对象不跨越队列边界。
enum Paginator {

    /// 排版容器的高度上限。
    ///
    /// 取一个足够大的有限值而非 `.greatestFiniteMagnitude`：
    /// 后者在某些路径上会触发浮点溢出，导致布局异常。
    /// 1e7 pt 约等于 3500 屏，远超任何单章的实际高度。
    private static let layoutHeightLimit: CGFloat = 10_000_000

    /// 对一章文本分页。
    ///
    /// - Parameters:
    ///   - attributedText: 已应用排版属性的章节文本。
    ///   - profile: 排版指纹（决定可用宽度与页高）。
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

        let pageWidth = max(1, profile.contentWidth)
        let pageHeight = max(1, profile.contentHeight)

        // 建立整章排版栈。容器高度极大 → 一次排完，不做分页。
        let contentStorage = NSTextContentStorage()
        contentStorage.attributedString = attributedText

        let layoutManager = NSTextLayoutManager()
        layoutManager.usesFontLeading = true
        layoutManager.usesHyphenation = false

        let container = NSTextContainer(
            size: CGSize(width: pageWidth, height: layoutHeightLimit)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.textContainer = container

        contentStorage.addTextLayoutManager(layoutManager)

        // 强制完成整章布局，保证后续枚举到真实几何
        layoutManager.ensureLayout(for: contentStorage.documentRange)

        let lines = collectLines(
            layoutManager: layoutManager,
            contentStorage: contentStorage,
            totalLength: length
        )

        guard !lines.isEmpty else {
            return PaginatedChapter(
                chapterIndex: chapterIndex,
                characterCount: length,
                slices: [PageSlice(range: NSRange(location: 0, length: length), pageIndex: 0)]
            )
        }

        let slices = groupIntoPages(
            lines: lines,
            pageHeight: pageHeight,
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
    /// 跨队列调用的入口：参数全部是 `Sendable` 值类型，
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

    // MARK: - 行信息收集

    /// 一行的排版信息。
    private struct LineInfo {
        /// 该行在源文本中的字符区间。
        var range: NSRange
        /// 该行顶部的绝对 Y 坐标（相对排版起点）。
        var minY: CGFloat
        /// 该行底部绝对 Y 坐标。
        var maxY: CGFloat
    }

    /// 枚举全部行，记录字符区间与绝对 Y 坐标。
    ///
    /// 用「fragment 的 Y + 行相对 fragment 的 Y」得到绝对坐标：
    /// `textLineFragments[i].typographicBounds.origin` 是相对
    /// 所属 fragment 的偏移，不是相对文档的。
    private static func collectLines(
        layoutManager: NSTextLayoutManager,
        contentStorage: NSTextContentStorage,
        totalLength: Int
    ) -> [LineInfo] {
        var lines: [LineInfo] = []
        let documentStart = contentStorage.documentRange.location

        layoutManager.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentFrame = fragment.layoutFragmentFrame
            let fragmentTop = fragmentFrame.minY

            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                let lineTop = fragmentTop + bounds.minY
                let lineBottom = lineTop + bounds.height
                let range = line.characterRange

                // 过滤越界与空行
                guard range.location >= 0,
                      range.length >= 0,
                      range.location + range.length <= totalLength else {
                    continue
                }
                guard bounds.height > 0 else { continue }

                lines.append(
                    LineInfo(range: range, minY: lineTop, maxY: lineBottom)
                )
            }

            return true
        }

        return lines
    }

    // MARK: - 切页

    /// 按页高把行分组为页。
    ///
    /// 切分规则：
    /// - 累积行高，超过页高时开新页
    /// - 单行本身超过页高（超大字号 / 巨图）时单独成页，防止死循环
    /// - 页的 `yOffset` 取该页第一行的顶部 Y，渲染时据此平移
    private static func groupIntoPages(
        lines: [LineInfo],
        pageHeight: CGFloat,
        totalLength: Int
    ) -> [PageSlice] {
        var slices: [PageSlice] = []
        var pageIndex = 0

        /// 当前页在源文本中的起始偏移。
        ///
        /// 关键：始终用「上一页结束位置」作为下一页起点，
        /// 而不是下一行首字符的位置。
        /// TextKit 2 的 `NSTextLineFragment.characterRange` 不含行尾换行符，
        /// 直接用行起点会让换行符落在任何页之外，造成区间断裂。
        var pageStart = 0
        /// 当前页首行的绝对 Y。
        var pageTop: CGFloat = 0
        /// 是否已开始记录当前页。
        var pageOpen = false

        for line in lines {
            let lineHeight = line.maxY - line.minY
            let lineEnd = line.range.location + line.range.length

            if !pageOpen {
                pageOpen = true
                pageTop = line.minY

                // 单行超过整页：独占一页
                if lineHeight > pageHeight {
                    let end = min(totalLength, lineEnd)
                    if end > pageStart {
                        slices.append(
                            PageSlice(
                                range: NSRange(location: pageStart, length: end - pageStart),
                                pageIndex: pageIndex,
                                yOffset: pageTop
                            )
                        )
                        pageIndex += 1
                    }
                    pageStart = end
                    pageOpen = false
                }
                continue
            }

            // 这一行放不下 → 结束当前页
            if line.maxY - pageTop > pageHeight {
                let end = min(totalLength, line.range.location)
                if end > pageStart {
                    slices.append(
                        PageSlice(
                            range: NSRange(location: pageStart, length: end - pageStart),
                            pageIndex: pageIndex,
                            yOffset: pageTop
                        )
                    )
                    pageIndex += 1
                    pageStart = end
                }

                // 开启新页
                pageTop = line.minY
                if lineHeight > pageHeight {
                    let soloEnd = min(totalLength, lineEnd)
                    if soloEnd > pageStart {
                        slices.append(
                            PageSlice(
                                range: NSRange(location: pageStart, length: soloEnd - pageStart),
                                pageIndex: pageIndex,
                                yOffset: pageTop
                            )
                        )
                        pageIndex += 1
                    }
                    pageStart = soloEnd
                    pageOpen = false
                }
                continue
            }
        }

        // 收尾：剩余文本全部归入最后一页
        if pageStart < totalLength {
            slices.append(
                PageSlice(
                    range: NSRange(location: pageStart, length: totalLength - pageStart),
                    pageIndex: pageIndex,
                    yOffset: pageTop
                )
            )
        }

        // 兜底
        if slices.isEmpty, totalLength > 0 {
            slices.append(
                PageSlice(
                    range: NSRange(location: 0, length: totalLength),
                    pageIndex: 0,
                    yOffset: 0
                )
            )
        }

        return slices
    }
}
