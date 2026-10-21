//
//  Paginator.swift
//  ModuReader
//
//  分页器。用 CoreText 的 CTFramesetter 计算每页字符区间。
//
//  为什么用 CTFramesetter 而不是 TextKit 2 的 layout fragment：
//  - `NSTextLayoutManager.enumerateTextLayoutFragments` 依赖 viewport 驱动，
//    在没有 `NSTextViewportLayoutController` 接管屏幕的情况下，
//    `layoutFragmentFrame` 可能为 .zero，导致所有内容被算作一页。
//  - `CTFramesetterCreateFrame` + `CTFrameGetVisibleStringRange` 直接返回
//    「给定矩形能放下多少字符」，语义明确、结果确定、无需 UI 环境。
//  - 分页是纯计算，与绘制解耦：TextKit 2 仍负责渲染（TextPageView）。
//
//  两者共享同一套 CoreText 断行引擎，因此分页边界与渲染结果一致。
//

import Foundation
import CoreText
import UIKit

/// 分页器。
///
/// 纯函数，无状态，可在任意队列调用。输入输出均为值类型。
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

        let pageSize = CGSize(
            width: max(1, profile.contentWidth),
            height: max(1, profile.contentHeight)
        )

        let framesetter = CTFramesetterCreateWithAttributedString(
            attributedText as CFAttributedString
        )

        var slices: [PageSlice] = []
        var start = 0
        var pageIndex = 0

        while start < length {
            let pageRect = CGRect(origin: .zero, size: pageSize)
            let path = CGPath(rect: pageRect, transform: nil)

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: start, length: 0),
                path,
                nil
            )

            let visible = CTFrameGetVisibleStringRange(frame)

            // 防御：任何情况下都必须推进，否则死循环
            guard visible.length > 0 else {
                // 单字符都放不下（页面过小），退化为「一页一章」
                slices.append(
                    PageSlice(
                        range: NSRange(location: start, length: length - start),
                        pageIndex: pageIndex
                    )
                )
                break
            }

            let sliceLength = min(visible.length, length - start)
            slices.append(
                PageSlice(
                    range: NSRange(location: start, length: sliceLength),
                    pageIndex: pageIndex
                )
            )

            start += sliceLength
            pageIndex += 1
        }

        return PaginatedChapter(
            chapterIndex: chapterIndex,
            characterCount: length,
            slices: slices
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
}
