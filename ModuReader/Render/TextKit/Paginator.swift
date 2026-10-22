//
//  Paginator.swift
//  ModuReader
//
//  分页器。用 CTFramesetter 计算每页字符区间。
//
//  ── 为什么分页不用 NSTextLayoutManager ──
//
//  TextKit 2 的布局是 **viewport 驱动**的：只有被 viewport 覆盖的区域
//  才会真正排版。实测三种尝试全部失败：
//
//  1. 容器高度 = 页高 → 只能拿到第一页的 fragment
//  2. 容器高度 = 极大值 + ensureLayout(documentRange)
//     → 10 万字耗时 13.8 秒，且 fragment Y 坐标失真
//  3. 容器高度 = 100,000pt
//     → 长文本仍只产出 1-2 页，超出部分未布局
//
//  CTFramesetter 是纯计算 API：给定矩形，返回「能放下多少字符」。
//  结果确定、无需 UI 环境、10 万字 0.48 秒。
//
//  ── 分页与渲染的一致性如何保证 ──
//
//  两者都基于 CoreText 的断行引擎，且使用**完全相同**的
//  NSAttributedString 与容器宽度。断行结果由 CoreText 决定，
//  因此分页边界与 TextKit 2 的渲染结果一致。
//
//  渲染侧用「页首字符位置」定位 fragment，不依赖 Y 坐标 ——
//  字符位置是唯一稳定的锚点。
//

import Foundation
import CoreText
import UIKit

/// 分页器。纯函数，无状态。
enum Paginator {

    /// 对一章文本分页。
    ///
    /// - Parameters:
    ///   - attributedText: 已应用排版属性的章节文本（含图片 attachment）。
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
    static func paginate(
        text: String,
        profile: TypographyProfile,
        textColor: RGBColor,
        chapterIndex: Int
    ) -> PaginatedChapter {
        let attributed = TextKitEngine.makeChapterAttributed(
            text: text,
            profile: profile,
            textColor: textColor
        )
        return paginate(
            attributedText: attributed,
            profile: profile,
            chapterIndex: chapterIndex
        )
    }
}
