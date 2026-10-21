//
//  ChapterSplitterTests.swift
//  ModuReaderTests
//

import Testing
import Foundation
@testable import ModuReader

@Suite("章节切分")
struct ChapterSplitterTests {

    @Test("标准中文章节标题")
    func standardChineseTitles() {
        let text = """
        第一章 开始
        这是第一章的内容。

        第二章 转折
        这是第二章的内容。

        第三章 结局
        这是第三章的内容。
        """

        let ranges = ChapterSplitter.split(text)
        #expect(ranges.count == 3)
        #expect(ranges[0].title == "第一章 开始")
        #expect(ranges[1].title == "第二章 转折")
        #expect(ranges[2].title == "第三章 结局")
    }

    @Test("切分结果覆盖全文且首尾相接")
    func rangesAreContiguous() {
        let text = """
        第一章 甲
        内容甲。

        第二章 乙
        内容乙。

        第三章 丙
        内容丙。
        """

        let ranges = ChapterSplitter.split(text)
        let ns = text as NSString
        var expectedStart = 0

        for range in ranges {
            #expect(range.range.location == expectedStart)
            expectedStart = range.range.location + range.range.length
        }
        #expect(expectedStart == ns.length)
    }

    @Test("无章节文本作为单章")
    func noChapters() {
        let text = "这是一段没有任何章节标记的普通文本。\n只有几行内容。"
        let ranges = ChapterSplitter.split(text)

        #expect(ranges.count == 1)
        #expect(ranges[0].title == ChapterSplitter.fallbackTitle)
        #expect(ranges[0].range.location == 0)
        #expect(ranges[0].range.length == (text as NSString).length)
    }

    @Test("章节不足 3 个时视为无章节")
    func tooFewChapters() {
        let text = """
        第一章 唯一的一章
        内容。

        第二章 第二章
        内容。
        """
        let ranges = ChapterSplitter.split(text)

        #expect(ranges.count == 1)
        #expect(ranges[0].title == ChapterSplitter.fallbackTitle)
    }

    @Test("数字列表误判防护")
    func numericListFalsePositive() {
        // 只有 5 个数字列表项，低于阈值 20，不应识别为章节
        let text = """
        购物清单
        1. 苹果
        2. 香蕉
        3. 橙子
        4. 葡萄
        5. 西瓜
        """
        let ranges = ChapterSplitter.split(text)
        #expect(ranges.count == 1)
    }

    @Test("数字列表达阈值时识别为章节")
    func numericListAboveThreshold() {
        var lines: [String] = []
        for i in 1...25 {
            lines.append("\(i). 第\(i)个条目")
            lines.append("这是第\(i)个条目的内容。")
        }
        let text = lines.joined(separator: "\n")

        let ranges = ChapterSplitter.split(text)
        #expect(ranges.count == 25)
        #expect(ranges.first?.title == "1. 第1个条目")
    }

    @Test("序章与番外")
    func specialSections() {
        let text = """
        序章
        序幕内容。

        第一章 开始
        第一章内容。

        番外 后日谈
        番外内容。
        """
        let ranges = ChapterSplitter.split(text)
        #expect(ranges.count == 3)
        #expect(ranges[0].title == "序章")
        #expect(ranges[2].title == "番外 后日谈")
    }

    @Test("文件开头有前言时单独成章")
    func leadingContentBecomesPreface() {
        let text = """
        这是一段放在章节之前的说明文字。

        第一章 开始
        第一章内容。

        第二章 继续
        第二章内容。

        第三章 结束
        第三章内容。
        """
        let ranges = ChapterSplitter.split(text)
        #expect(ranges.count == 4)
        #expect(ranges[0].title == "前言")
        #expect(ranges[1].title == "第一章 开始")
    }

    @Test("Chapter N 英文标题")
    func englishChapters() {
        let text = """
        Chapter 1 The Beginning
        Content one.

        Chapter 2 The Middle
        Content two.

        Chapter 3 The End
        Content three.
        """
        let ranges = ChapterSplitter.split(text)
        #expect(ranges.count == 3)
        #expect(ranges[0].title == "Chapter 1 The Beginning")
    }

    @Test("超长章节二次分块")
    func oversizedChapterIsSplit() {
        let header = "第一章 超长章节\n"
        let body = String(repeating: "这是一段很长的内容。\n", count: 12_000)
        let text = header + body

        let ranges = ChapterSplitter.split(text)
        // 超过 100,000 字应被切成多块
        #expect(ranges.count > 1)
        #expect(ranges[0].title == "第一章 超长章节")
        #expect(ranges[1].title.contains("续"))
    }

    @Test("空文本返回单章")
    func emptyText() {
        let ranges = ChapterSplitter.split("")
        #expect(ranges.count == 1)
        #expect(ranges[0].range.length == 0)
    }

    @Test("标题清洗去除不可见字符")
    func titleSanitization() {
        let text = "第一章\u{3000}标题\u{FEFF}\n内容。\n\n第二章 标题二\n内容。\n\n第三章 标题三\n内容。"
        let ranges = ChapterSplitter.split(text)
        #expect(ranges.count == 3)
        #expect(!ranges[0].title.contains("\u{FEFF}"))
    }
}
