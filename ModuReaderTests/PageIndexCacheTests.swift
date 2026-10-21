//
//  PageIndexCacheTests.swift
//  ModuReaderTests
//

import Testing
import Foundation
@testable import ModuReader

@Suite("分页缓存")
struct PageIndexCacheTests {

    private func makeCache() throws -> (PageIndexCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageCache-\(UUID().uuidString)", isDirectory: true)
        let cache = try PageIndexCache(rootURL: root)
        return (cache, root)
    }

    private func makeProfile(
        fontSize: CGFloat = 19,
        width: CGFloat = 320
    ) -> TypographyProfile {
        TypographyProfile(
            fontSize: fontSize,
            contentWidth: width,
            contentHeight: 480
        )
    }

    private func makeChapter(index: Int = 0, count: Int = 3) -> PaginatedChapter {
        let slices = (0..<count).map { i in
            PageSlice(range: NSRange(location: i * 100, length: 100), pageIndex: i)
        }
        return PaginatedChapter(chapterIndex: index, characterCount: count * 100, slices: slices)
    }

    @Test("写入后能读回")
    func storeAndLoad() throws {
        let (cache, _) = try makeCache()
        let bookID = UUID()
        let profile = makeProfile()
        let chapter = makeChapter()

        cache.store(chapter, bookID: bookID, profile: profile)
        let loaded = cache.load(bookID: bookID, chapterIndex: 0, profile: profile)

        #expect(loaded != nil)
        #expect(loaded?.pageCount == 3)
        #expect(loaded?.slices == chapter.slices)
        #expect(loaded?.characterCount == 300)
    }

    @Test("未写入时返回 nil")
    func missReturnsNil() throws {
        let (cache, _) = try makeCache()
        let result = cache.load(bookID: UUID(), chapterIndex: 0, profile: makeProfile())
        #expect(result == nil)
    }

    @Test("不同排版指纹互不干扰")
    func differentProfilesIsolated() throws {
        let (cache, _) = try makeCache()
        let bookID = UUID()

        let small = makeProfile(fontSize: 14)
        let large = makeProfile(fontSize: 28)

        cache.store(makeChapter(count: 3), bookID: bookID, profile: small)
        cache.store(makeChapter(count: 7), bookID: bookID, profile: large)

        let smallLoaded = cache.load(bookID: bookID, chapterIndex: 0, profile: small)
        let largeLoaded = cache.load(bookID: bookID, chapterIndex: 0, profile: large)

        #expect(smallLoaded?.pageCount == 3)
        #expect(largeLoaded?.pageCount == 7)
    }

    @Test("不同章节互不干扰")
    func differentChaptersIsolated() throws {
        let (cache, _) = try makeCache()
        let bookID = UUID()
        let profile = makeProfile()

        cache.store(makeChapter(index: 0, count: 2), bookID: bookID, profile: profile)
        cache.store(makeChapter(index: 1, count: 5), bookID: bookID, profile: profile)

        #expect(cache.load(bookID: bookID, chapterIndex: 0, profile: profile)?.pageCount == 2)
        #expect(cache.load(bookID: bookID, chapterIndex: 1, profile: profile)?.pageCount == 5)
    }

    @Test("不同书籍互不干扰")
    func differentBooksIsolated() throws {
        let (cache, _) = try makeCache()
        let profile = makeProfile()
        let bookA = UUID()
        let bookB = UUID()

        cache.store(makeChapter(count: 2), bookID: bookA, profile: profile)
        cache.store(makeChapter(count: 9), bookID: bookB, profile: profile)

        #expect(cache.load(bookID: bookA, chapterIndex: 0, profile: profile)?.pageCount == 2)
        #expect(cache.load(bookID: bookB, chapterIndex: 0, profile: profile)?.pageCount == 9)
    }

    @Test("删除书籍缓存后读不到")
    func removeAllForBook() throws {
        let (cache, _) = try makeCache()
        let bookID = UUID()
        let profile = makeProfile()

        cache.store(makeChapter(), bookID: bookID, profile: profile)
        #expect(cache.load(bookID: bookID, chapterIndex: 0, profile: profile) != nil)

        cache.removeAll(bookID: bookID)
        #expect(cache.load(bookID: bookID, chapterIndex: 0, profile: profile) == nil)
    }

    @Test("损坏的缓存文件被忽略并删除")
    func corruptedCacheIgnored() throws {
        let (cache, root) = try makeCache()
        let bookID = UUID()
        let profile = makeProfile()

        cache.store(makeChapter(), bookID: bookID, profile: profile)
        #expect(cache.load(bookID: bookID, chapterIndex: 0, profile: profile) != nil)

        // 找到并破坏缓存文件
        let bookDir = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        let files = try FileManager.default.subpathsOfDirectory(atPath: bookDir.path)
            .filter { $0.hasSuffix(".pageindex") }
        #expect(!files.isEmpty)

        for file in files {
            try Data("not json".utf8).write(
                to: bookDir.appendingPathComponent(file)
            )
        }

        #expect(cache.load(bookID: bookID, chapterIndex: 0, profile: profile) == nil)
    }

    @Test("缓存键哈希稳定且文件名安全")
    func cacheKeyHashStable() {
        let profile = makeProfile()
        let first = profile.cacheKeyHash
        let second = profile.cacheKeyHash

        #expect(first == second)
        #expect(first.count == 8)
        #expect(first.allSatisfy { $0.isHexDigit })
    }

    @Test("排版参数变化产生不同哈希")
    func cacheKeyHashDiffers() {
        let a = makeProfile(fontSize: 19)
        let b = makeProfile(fontSize: 20)
        #expect(a.cacheKeyHash != b.cacheKeyHash)
    }

    @Test("LRU 清理后总量低于上限")
    func evictionReducesSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageCacheLRU-\(UUID().uuidString)", isDirectory: true)
        // 上限设得极小，确保写入后触发清理
        let cache = try PageIndexCache(rootURL: root, sizeLimit: 4096)

        let bookID = UUID()
        for chapterIndex in 0..<40 {
            let profile = makeProfile(fontSize: CGFloat(12 + chapterIndex % 20))
            cache.store(
                makeChapter(index: chapterIndex, count: 20),
                bookID: bookID,
                profile: profile
            )
        }

        let before = cache.totalSize()
        #expect(before > 0)

        cache.evictIfNeeded()
        let after = cache.totalSize()

        #expect(after <= before)
        #expect(after <= 4096)
    }
}
