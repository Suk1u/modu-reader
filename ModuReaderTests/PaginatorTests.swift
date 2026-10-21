//
//  PaginatorTests.swift
//  ModuReaderTests
//
//  分页器测试。这些用例不依赖 UIKit 渲染，只验证分页结果的正确性。
//

import Testing
import UIKit
@testable import ModuReader

@Suite("分页器")
struct PaginatorTests {

    private func makeProfile(
        width: CGFloat = 320,
        height: CGFloat = 480
    ) -> TypographyProfile {
        TypographyProfile(
            fontFamily: .system,
            fontSize: 19,
            lineHeightMultiple: 1.8,
            paragraphSpacing: 8,
            firstLineIndent: 2,
            letterSpacing: 0,
            contentWidth: width,
            contentHeight: height
        )
    }

    @Test("空文本产生单页")
    func emptyText() {
        let result = Paginator.paginate(
            text: "",
            profile: makeProfile(),
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )
        #expect(result.pageCount == 1)
        #expect(result.characterCount == 0)
    }

    @Test("短文本产生单页")
    func shortText() {
        let text = "第一行\n第二行"
        let result = Paginator.paginate(
            text: text,
            profile: makeProfile(),
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )
        #expect(result.pageCount == 1)
        #expect(result.slices[0].range.length == (text as NSString).length)
    }

    @Test("长文本产生多页")
    func longText() {
        let text = String(repeating: "这是一段用于测试分页的正文内容。\n", count: 300)
        let result = Paginator.paginate(
            text: text,
            profile: makeProfile(),
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )
        #expect(result.pageCount > 1)
    }

    @Test("分页区间首尾相接且覆盖全文")
    func slicesAreContiguous() {
        let text = String(repeating: "这是一段用于测试分页的正文内容。\n", count: 200)
        let result = Paginator.paginate(
            text: text,
            profile: makeProfile(),
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )

        var expectedStart = 0
        for slice in result.slices {
            #expect(slice.range.location == expectedStart)
            expectedStart = slice.range.location + slice.range.length
        }
        #expect(expectedStart == (text as NSString).length)
    }

    @Test("同一输入分页结果稳定")
    func deterministic() {
        let text = String(repeating: "稳定性测试内容。\n", count: 150)
        let profile = makeProfile()

        let first = Paginator.paginate(
            text: text, profile: profile,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )
        let second = Paginator.paginate(
            text: text, profile: profile,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )

        #expect(first.pageCount == second.pageCount)
        #expect(first.slices == second.slices)
    }

    @Test("字号增大后页数增加")
    func largerFontMorePages() {
        let text = String(repeating: "字号测试内容。\n", count: 150)

        var small = makeProfile()
        small.fontSize = 14

        var large = makeProfile()
        large.fontSize = 28

        let smallResult = Paginator.paginate(
            text: text, profile: small,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )
        let largeResult = Paginator.paginate(
            text: text, profile: large,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )

        #expect(largeResult.pageCount > smallResult.pageCount)
    }

    @Test("页面高度减半后页数增加")
    func shorterPageMorePages() {
        let text = String(repeating: "页面尺寸测试。\n", count: 150)

        let tall = makeProfile(height: 600)
        let short = makeProfile(height: 300)

        let tallResult = Paginator.paginate(
            text: text, profile: tall,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )
        let shortResult = Paginator.paginate(
            text: text, profile: short,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )

        #expect(shortResult.pageCount > tallResult.pageCount)
    }

    // MARK: - PaginatedChapter

    @Test("按字符偏移查找页号")
    func pageIndexForOffset() {
        let chapter = PaginatedChapter(
            chapterIndex: 0,
            characterCount: 300,
            slices: [
                PageSlice(range: NSRange(location: 0, length: 100), pageIndex: 0),
                PageSlice(range: NSRange(location: 100, length: 100), pageIndex: 1),
                PageSlice(range: NSRange(location: 200, length: 100), pageIndex: 2),
            ]
        )

        #expect(chapter.pageIndex(forCharacterOffset: 0) == 0)
        #expect(chapter.pageIndex(forCharacterOffset: 50) == 0)
        #expect(chapter.pageIndex(forCharacterOffset: 100) == 1)
        #expect(chapter.pageIndex(forCharacterOffset: 150) == 1)
        #expect(chapter.pageIndex(forCharacterOffset: 250) == 2)
        #expect(chapter.pageIndex(forCharacterOffset: 999) == 2)
    }

    @Test("空分页返回第 0 页")
    func emptyPaginationPageIndex() {
        let chapter = PaginatedChapter(chapterIndex: 0, characterCount: 0, slices: [])
        #expect(chapter.pageIndex(forCharacterOffset: 0) == 0)
        #expect(chapter.characterOffset(forPageIndex: 0) == 0)
    }
}

// MARK: - TextKit 2 分页特性

@Suite("TextKit 2 分页")
struct TextKitPaginatorTests {

    private func makeProfile(width: CGFloat = 320, height: CGFloat = 480) -> TypographyProfile {
        TypographyProfile(
            fontFamily: .system,
            fontSize: 19,
            lineHeightMultiple: 1.8,
            paragraphSpacing: 8,
            firstLineIndent: 2,
            letterSpacing: 0,
            contentWidth: width,
            contentHeight: height
        )
    }

    @Test("每页的 yOffset 单调递增")
    func yOffsetMonotonic() {
        let text = String(repeating: "这是一段用于测试分页的正文内容。\n", count: 300)
        let result = Paginator.paginate(
            text: text,
            profile: makeProfile(),
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )

        #expect(result.pageCount > 1)

        var previous: CGFloat = -1
        for slice in result.slices {
            #expect(slice.yOffset >= previous)
            previous = slice.yOffset
        }
        #expect(result.slices[0].yOffset == 0)
    }

    @Test("每页内容高度不超过页高")
    func pageHeightRespected() {
        let text = String(repeating: "测试内容行。\n", count: 400)
        let profile = makeProfile(height: 480)
        let result = Paginator.paginate(
            text: text,
            profile: profile,
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )

        // 用 yOffset 差值反推每页高度
        for index in 0..<(result.slices.count - 1) {
            let height = result.slices[index + 1].yOffset - result.slices[index].yOffset
            #expect(height <= profile.contentHeight + 1)
        }
    }

    @Test("分页区间仍首尾相接")
    func rangesContiguous() {
        let text = String(repeating: "连续性测试。\n", count: 200)
        let result = Paginator.paginate(
            text: text,
            profile: makeProfile(),
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )

        var expected = 0
        for slice in result.slices {
            #expect(slice.range.location == expected)
            expected = slice.range.location + slice.range.length
        }
        #expect(expected == (text as NSString).length)
    }

    @Test("字号变化产生不同分页")
    func fontSizeAffectsPagination() {
        let text = String(repeating: "字号测试。\n", count: 200)

        var small = makeProfile()
        small.fontSize = 14
        var large = makeProfile()
        large.fontSize = 28

        let a = Paginator.paginate(
            text: text, profile: small,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )
        let b = Paginator.paginate(
            text: text, profile: large,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )

        #expect(b.pageCount > a.pageCount)
    }

    @Test("同输入分页结果稳定")
    func deterministic() {
        let text = String(repeating: "稳定性测试内容。\n", count: 150)
        let profile = makeProfile()

        let first = Paginator.paginate(
            text: text, profile: profile,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )
        let second = Paginator.paginate(
            text: text, profile: profile,
            textColor: ReaderTheme.paper.text, chapterIndex: 0
        )

        #expect(first.slices == second.slices)
    }
}
