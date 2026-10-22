//
//  Paginator.swift
//  ModuReader
//
//  分页器。基于 `ChapterLayout` 的排版结果计算页区间。
//
//  ── 为什么分页与渲染必须共用同一份排版 ──
//
//  之前分页用 CTFramesetter、渲染用 TextKit 2。两者虽都基于 CoreText，
//  但对段落间距、首行缩进、attachment 高度的解释有细微差异。
//  这些差异累积几十行后，分页算出的「第 N 页首行」与渲染实际画出的
//  位置就对不上 —— 表现为空白页、文字错位、进度记录不准。
//
//  现在：一次排版 → 分页只读 Y 坐标 → 渲染按同一 Y 坐标绘制。
//  不存在任何几何偏差。
//

import UIKit

/// 分页结果。
struct PaginationResult: Sendable {
    var slices: [PageSlice]
    /// 整章排版高度。
    var contentHeight: CGFloat
}

/// 分页器。
@MainActor
enum Paginator {

    /// 单章最大字符数。
    ///
    /// 超过此长度的章节在导入时已被切分为虚拟块（见 `ChapterSplitter`），
    /// 这里是第二道防线：万一有超长章节漏网，按此长度二次切分，
    /// 避免一次排版几十万字导致卡顿。
    static let maxChapterCharacters = 12_000

    /// 对已排版的章节计算页区间。
    ///
    /// - Parameters:
    ///   - layout: 已完成的整章排版。
    ///   - pageHeight: 页高（已扣除上下内边距）。
    ///   - totalLength: 章节字符总数。
    /// - Returns: 页区间列表。
    static func paginate(
        layout: ChapterLayout,
        pageHeight: CGFloat,
        totalLength: Int
    ) -> PaginationResult {
        guard layout.isReady, totalLength > 0, pageHeight > 0 else {
            return PaginationResult(
                slices: [PageSlice(range: NSRange(location: 0, length: max(0, totalLength)), pageIndex: 0)],
                contentHeight: 0
            )
        }

        var slices: [PageSlice] = []
        var pageIndex = 0
        var pageStart = 0
        var pageTop: CGFloat = 0
        var hasOpenPage = false

        layout.enumerateLines { line in
            let lineTop = line.minY
            let lineBottom = line.maxY
            let lineStart = line.range.location
            let lineEnd = line.range.location + line.range.length

            guard lineStart >= pageStart else { return }

            if !hasOpenPage {
                hasOpenPage = true
                pageTop = lineTop
            }

            // 这一行放不下 → 结束当前页
            if lineBottom - pageTop > pageHeight, lineStart > pageStart {
                slices.append(
                    PageSlice(
                        range: NSRange(location: pageStart, length: lineStart - pageStart),
                        pageIndex: pageIndex,
                        yOffset: pageTop
                    )
                )
                pageIndex += 1
                pageStart = lineStart
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
                hasOpenPage = false
            }
        }

        // 收尾
        if pageStart < totalLength {
            slices.append(
                PageSlice(
                    range: NSRange(location: pageStart, length: totalLength - pageStart),
                    pageIndex: pageIndex,
                    yOffset: pageTop
                )
            )
        }

        if slices.isEmpty {
            slices.append(
                PageSlice(range: NSRange(location: 0, length: totalLength), pageIndex: 0)
            )
        }

        return PaginationResult(slices: slices, contentHeight: layout.contentHeight)
    }
}

// MARK: - 行枚举

extension ChapterLayout {

    /// 一行排版信息。
    struct Line {
        var range: NSRange
        var minY: CGFloat
        var maxY: CGFloat
    }

    /// 枚举整章所有行。
    ///
    /// 行的绝对 Y = fragment 的 Y + 行在 fragment 内的相对 Y。
    /// `typographicBounds.origin` 是相对所属 fragment 的偏移。
    func enumerateLines(_ body: (Line) -> Void) {
        guard isReady else { return }
        let totalLength = contentStorage.attributedString?.length ?? 0

        layoutManager.enumerateTextLayoutFragments(
            from: nil,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentTop = fragment.layoutFragmentFrame.minY

            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                guard bounds.height > 0 else { continue }

                let range = line.characterRange
                guard range.location >= 0,
                      range.length > 0,
                      range.location + range.length <= totalLength else {
                    continue
                }

                body(
                    Line(
                        range: range,
                        minY: fragmentTop + bounds.minY,
                        maxY: fragmentTop + bounds.minY + bounds.height
                    )
                )
            }
            return true
        }
    }
}
