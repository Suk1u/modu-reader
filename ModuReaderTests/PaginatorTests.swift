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

