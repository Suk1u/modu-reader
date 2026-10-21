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

        // 建立整章排版栈。
        //
        // 容器高度设为极大值，让整章在一个容器内连续排版，
        // 这样行的 Y 坐标是连续的绝对坐标，分页只需按页高切分。
        //
        // 注意：不能对 documentRange 调 ensureLayout —— 那会强制布局全文，
        // 10 万字章节实测耗时 13 秒。改为按需布局：
        // 枚举 fragment 时 TextKit 会自动布局到当前枚举位置，
        // 遇到超出页高的行就停止，无需排完全文。
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

        // 边枚举边切页：一次遍历同时完成「取行几何」与「按页高分组」，
        // 避免先收集全部行（那等价于排完全文）。
        let slices = paginateInOnePass(
            layoutManager: layoutManager,
            contentStorage: contentStorage,
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

    // MARK: - 单遍分页

    /// 边枚举行边切页。
    ///
    /// 一次遍历同时完成「取行几何」与「按页高分组」。
    /// 这样 TextKit 只会按需布局到当前枚举位置，
    /// 不会像 `ensureLayout(for: documentRange)` 那样排完全文。
    private static func paginateInOnePass(
        layoutManager: NSTextLayoutManager,
        contentStorage: NSTextContentStorage,
        pageHeight: CGFloat,
        totalLength: Int
    ) -> [PageSlice] {
        var slices: [PageSlice] = []
        var pageIndex = 0

        /// 当前页在源文本中的起始偏移。
        ///
        /// 始终用「上一页结束位置」作为下一页起点：
        /// TextKit 2 的行 characterRange 不含行尾换行符，
        /// 若用下一行起点会让换行符落在任何页之外，造成区间断裂。
        var pageStart = 0
        var pageTop: CGFloat = 0
        var pageOpen = false
        var reachedEnd = false

        layoutManager.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentTop = fragment.layoutFragmentFrame.minY

            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                guard bounds.height > 0 else { continue }

                let lineTop = fragmentTop + bounds.minY
                let lineBottom = lineTop + bounds.height
                let lineRange = line.characterRange

                guard lineRange.location >= 0,
                      lineRange.location + lineRange.length <= totalLength else {
                    continue
                }

                let lineEnd = lineRange.location + lineRange.length

                // 开始一页
                if !pageOpen {
                    pageOpen = true
                    pageTop = lineTop
                }

                // 这一行放不下 → 结束当前页
                if lineBottom - pageTop > pageHeight, lineRange.location > pageStart {
                    let end = min(totalLength, lineRange.location)
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
                    pageTop = lineTop
                }

                // 单行超过整页：独占一页，防止死循环
                if lineBottom - lineTop > pageHeight {
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
                        pageStart = end
                    }
                    pageOpen = false
                    continue
                }

                // 推进到本章末尾时停止枚举
                if lineEnd >= totalLength {
                    reachedEnd = true
                    return false
                }
            }

            return true
        }

        // 收尾：剩余文本归入最后一页
        if pageStart < totalLength {
            slices.append(
                PageSlice(
                    range: NSRange(location: pageStart, length: totalLength - pageStart),
                    pageIndex: pageIndex,
                    yOffset: pageTop
                )
            )
        }

        _ = reachedEnd
        return slices
    }
}
