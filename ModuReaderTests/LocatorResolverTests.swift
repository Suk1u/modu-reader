//
//  LocatorResolverTests.swift
//  ModuReaderTests
//

import Testing
import Foundation
@testable import ModuReader

@Suite("位置重定位")
struct LocatorResolverTests {

    private let sampleText = "第一章 开始\n" + String(repeating: "这是一段用于测试的正文内容。", count: 50)

    @Test("charOffset 精确命中")
    func charOffsetExact() {
        let locator = Locator(
            href: "chapters/0000.txt",
            locations: Locations(charOffset: 120)
        )
        let resolved = LocatorResolver.resolve(locator, in: sampleText)
        #expect(resolved == 120)
    }

    @Test("charOffset 越界时回退到模糊匹配")
    func charOffsetOutOfBounds() {
        let text = "第一章 开始\n这是正文。"
        let locator = Locator(
            href: "chapters/0000.txt",
            locations: Locations(charOffset: 99_999),
            text: TextQuote(highlight: "这是正文。")
        )
        let resolved = LocatorResolver.resolve(locator, in: text)
        #expect(resolved == (text as NSString).range(of: "这是正文。").location)
    }

    @Test("highlight 精确匹配")
    func highlightExact() {
        let text = "第一章 开始\n目标句子在这里。后面还有内容。"
        let expected = (text as NSString).range(of: "目标句子在这里。").location
        let locator = Locator(
            href: "chapters/0000.txt",
            locations: Locations(),
            text: TextQuote(highlight: "目标句子在这里。")
        )
        let resolved = LocatorResolver.resolve(locator, in: text)
        #expect(resolved == expected)
    }

    @Test("highlight 含前后文夹逼")
    func highlightWithContext() {
        let text = "前面的一些内容。目标片段。后面的一些内容。"
        let expected = (text as NSString).range(of: "目标片段。").location
        let locator = Locator(
            href: "chapters/0000.txt",
            locations: Locations(),
            text: TextQuote(
                before: "前面的一些内容。",
                highlight: "目标片段。",
                after: "后面的一些内容。"
            )
        )
        let resolved = LocatorResolver.resolve(locator, in: text)
        #expect(resolved == expected)
    }

    @Test("progression 兜底")
    func progressionFallback() {
        let text = String(repeating: "a", count: 1000)
        let locator = Locator(
            href: "chapters/0000.txt",
            locations: Locations(progression: 0.5)
        )
        let resolved = LocatorResolver.resolve(locator, in: text)
        #expect(resolved == 500)
    }

    @Test("空文本返回 0")
    func emptyText() {
        let locator = Locator(href: "chapters/0000.txt")
        let resolved = LocatorResolver.resolve(locator, in: "")
        #expect(resolved == 0)
    }

    @Test("全部信息缺失返回 0")
    func noInformation() {
        let locator = Locator(href: "chapters/0000.txt", locations: Locations())
        let resolved = LocatorResolver.resolve(locator, in: sampleText)
        #expect(resolved == 0)
    }

    // MARK: - makeLocator

    @Test("构造 Locator 时计算 progression")
    func makeLocatorProgression() {
        let text = String(repeating: "a", count: 100)
        let locator = LocatorResolver.makeLocator(
            text: text,
            offset: 25,
            href: "chapters/0000.txt",
            totalCharacters: 400,
            charactersBeforeResource: 100
        )

        #expect(locator.locations.charOffset == 25)
        #expect(locator.locations.progression == 0.25)
        // (100 + 25) / 400 = 0.3125
        #expect(abs((locator.locations.totalProgression ?? 0) - 0.3125) < 0.0001)
    }

    @Test("构造 Locator 时截取文本引用")
    func makeLocatorQuote() {
        let text = String(repeating: "字", count: 200)
        let locator = LocatorResolver.makeLocator(
            text: text,
            offset: 100,
            href: "chapters/0000.txt",
            totalCharacters: 200
        )

        #expect(locator.text != nil)
        #expect(!(locator.text?.highlight.isEmpty ?? true))
    }

    @Test("偏移超出范围时被裁剪")
    func makeLocatorClampsOffset() {
        let text = String(repeating: "a", count: 50)
        let locator = LocatorResolver.makeLocator(
            text: text,
            offset: 999,
            href: "chapters/0000.txt",
            totalCharacters: 50
        )
        #expect(locator.locations.charOffset == 50)
    }

    @Test("总字符数为 0 时 totalProgression 为 0")
    func makeLocatorZeroTotal() {
        let locator = LocatorResolver.makeLocator(
            text: "abc",
            offset: 1,
            href: "chapters/0000.txt",
            totalCharacters: 0
        )
        #expect(locator.locations.totalProgression == 0)
    }
}
