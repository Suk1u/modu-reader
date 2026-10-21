//
//  ReadingProgressTests.swift
//  ModuReaderTests
//
//  进度持久化测试：验证 Locator 的编解码往返与跨排版恢复。
//  这是「杀进程重进位置一致」「换字号不丢位置」的底层保证。
//

import Testing
import Foundation
import SwiftData
@testable import ModuReader

@Suite("进度持久化")
@MainActor
struct ReadingProgressTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModuModelContainer.makeInMemory()
        return ModelContext(container)
    }

    private func makeBook(in context: ModelContext) -> BookEntity {
        let book = BookEntity(
            title: "测试书",
            kind: .text,
            formatExtension: "txt",
            relativePath: UUID().uuidString,
            totalCharacters: 10_000,
            chapterCount: 5
        )
        context.insert(book)
        try? context.save()
        return book
    }

    @Test("Locator 编解码往返无损")
    func locatorRoundTrip() throws {
        let locator = Locator(
            href: "chapters/0003.txt",
            mediaType: "text/plain",
            locations: Locations(
                progression: 0.42,
                totalProgression: 0.31,
                charOffset: 1234
            ),
            text: TextQuote(
                before: "前面",
                highlight: "目标句",
                after: "后面"
            )
        )

        let data = try JSONEncoder().encode(locator)
        let decoded = try JSONDecoder().decode(Locator.self, from: data)

        #expect(decoded == locator)
        #expect(decoded.locations.charOffset == 1234)
        #expect(decoded.text?.highlight == "目标句")
    }

    @Test("进度写入数据库后可读回")
    func progressPersists() throws {
        let context = try makeContext()
        let book = makeBook(in: context)

        let locator = Locator(
            href: "chapters/0001.txt",
            locations: Locations(progression: 0.5, totalProgression: 0.2, charOffset: 500)
        )
        let data = try JSONEncoder().encode(locator)

        let progress = ProgressEntity(
            locatorJSON: data,
            totalProgression: 0.2
        )
        progress.book = book
        context.insert(progress)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ProgressEntity>())
        #expect(fetched.count == 1)
        #expect(fetched[0].locator?.locations.charOffset == 500)
        #expect(abs(fetched[0].totalProgression - 0.2) < 0.0001)
    }

    @Test("更新进度覆盖旧值")
    func progressUpdate() throws {
        let context = try makeContext()
        let book = makeBook(in: context)

        let first = Locator(href: "chapters/0000.txt", locations: Locations(charOffset: 100))
        let progress = ProgressEntity(
            locatorJSON: try JSONEncoder().encode(first),
            totalProgression: 0.1
        )
        progress.book = book
        context.insert(progress)
        try context.save()

        let second = Locator(href: "chapters/0002.txt", locations: Locations(charOffset: 900))
        progress.update(with: second, totalProgression: 0.75)
        try context.save()

        #expect(progress.locator?.locations.charOffset == 900)
        #expect(progress.locator?.href == "chapters/0002.txt")
        #expect(abs(progress.totalProgression - 0.75) < 0.0001)
    }

    @Test("损坏的 Locator JSON 不崩溃")
    func corruptedLocatorReturnsNil() throws {
        let progress = ProgressEntity(
            locatorJSON: Data("not json".utf8),
            totalProgression: 0.5
        )
        #expect(progress.locator == nil)
    }

    @Test("换字号后按字符偏移恢复到同一位置")
    func positionSurvivesFontChange() {
        // 模拟：同一章在不同字号下分成不同页数
        let chapterText = String(repeating: "这是一段测试正文。", count: 500)

        // 小字号：页少
        let small = TypographyProfile(fontSize: 14, contentWidth: 320, contentHeight: 480)
        let smallChapter = Paginator.paginate(
            text: chapterText,
            profile: small,
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )

        // 大字号：页多
        let large = TypographyProfile(fontSize: 26, contentWidth: 320, contentHeight: 480)
        let largeChapter = Paginator.paginate(
            text: chapterText,
            profile: large,
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )

        #expect(largeChapter.pageCount > smallChapter.pageCount)

        // 在小字号下停在第 3 页，记下字符偏移
        let offset = smallChapter.characterOffset(forPageIndex: 2)
        #expect(offset > 0)

        // 换到大字号，用同一个字符偏移定位
        let newPageIndex = largeChapter.pageIndex(forCharacterOffset: offset)
        let recoveredOffset = largeChapter.characterOffset(forPageIndex: newPageIndex)

        // 恢复后所在页的起始位置不应晚于原偏移
        #expect(recoveredOffset <= offset)
        // 且偏移应落在该页范围内
        let slice = largeChapter.slices[newPageIndex]
        #expect(offset >= slice.range.location)
        #expect(offset < slice.range.location + slice.range.length)
    }

    @Test("Locator 从字符偏移构造后能解析回同一位置")
    func locatorRoundTripThroughResolver() {
        let text = String(repeating: "abcdefghij", count: 100)
        let offset = 456

        let locator = LocatorResolver.makeLocator(
            text: text,
            offset: offset,
            href: "chapters/0000.txt",
            totalCharacters: 1000,
            charactersBeforeResource: 0
        )

        let resolved = LocatorResolver.resolve(locator, in: text)
        #expect(resolved == offset)
    }

    @Test("删除书籍级联删除进度")
    func cascadeDelete() throws {
        let context = try makeContext()
        let book = makeBook(in: context)

        let locator = Locator(href: "chapters/0000.txt", locations: Locations(charOffset: 10))
        let progress = ProgressEntity(
            locatorJSON: try JSONEncoder().encode(locator),
            totalProgression: 0.01
        )
        progress.book = book
        context.insert(progress)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProgressEntity>()).count == 1)

        context.delete(book)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProgressEntity>()).isEmpty)
    }
}
