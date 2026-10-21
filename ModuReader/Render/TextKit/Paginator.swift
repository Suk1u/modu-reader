//
//  Paginator.swift
//  ModuReader
//
//  分页器。用 CoreText 的 CTFramesetter 计算每页字符区间。
//
//  ── 为什么分页用 CTFramesetter，渲染用 TextKit 2 ──
//
//  TextKit 2 的 NSTextLayoutManager 设计上依赖 viewport 驱动：
//  - 容器高度设为页高时，只能拿到第一页的 fragment，
//    后续内容需要 viewport 推进才会布局
//  - 容器高度设为极大值时，TextKit 会把每段的高度算成容器高度，
//    实测 10 万字章节的 fragment Y 累加到 19525，分页结果完全错误
//  - 对 documentRange 调 ensureLayout 会强制布局全文，
//    10 万字实测耗时 13.8 秒
//
//  CTFramesetter 是纯计算 API：给定矩形，返回「能放下多少字符」。
//  结果确定、无需 UI 环境、10 万字约 0.7 秒。
//
//  两者都基于 CoreText 的断行引擎，且使用同一份 NSAttributedString
//  与相同宽度，因此分页边界与 TextKit 2 的渲染结果一致。
//
//  ── 渲染为什么仍用 TextKit 2 ──
//  NSTextAttachment 在 TextKit 2 里能正确参与行高计算与排版，
//  图片可以实现真正的图文混排（挤压文字行），而非叠加在文字上方。
//

import Foundation
import CoreText
import UIKit

/// 分页器。纯函数，无状态，可在任意后台队列调用。
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
                    pageIndex: pageIndex,
                    // 该页首字符在整章中的字符偏移。
                    // 渲染层据此定位（TextKit 2 里用字符位置而非 Y 坐标更可靠）。
                    yOffset: 0
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
}
