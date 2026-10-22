//
//  LargeFilePerformanceTests.swift
//  ModuReaderTests
//
//  大文件性能回归测试。
//
//  背景：用户导入 5.3MB 的 TXT 后「点击打开没反应」。
//  根因是导入链路在主线程做了全量解码 + 逐行正则匹配，
//  耗时过长导致界面无响应。这些用例锁住处理时间上限。
//

import Testing
import Foundation
@testable import ModuReader

@Suite("大文件性能")
@MainActor
struct LargeFilePerformanceTests {

    /// 构造一个约 5MB 的中文 TXT（带章节标题）。
    private func makeLargeText(targetBytes: Int) -> String {
        let chapterBody = String(repeating: "这是一段用于测试的中文正文内容，包含常见标点符号。\n", count: 30)
        var chapters: [String] = []
        var estimatedBytes = 0
        var index = 1

        while estimatedBytes < targetBytes {
            let title = "第\(index)章 测试章节标题\n"
            let chunk = title + chapterBody
            chapters.append(chunk)
            estimatedBytes += chunk.utf8.count
            index += 1
        }
        return chapters.joined()
    }

    @Test("5MB 文本编码探测在 3 秒内完成")
    func encodingDetectionOnLargeFile() {
        let text = makeLargeText(targetBytes: 5 * 1024 * 1024)
        let data = text.data(using: .utf8)!
        #expect(data.count > 4 * 1024 * 1024)

        let start = Date()
        let result = TextEncodingDetector.detect(data: data)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.text.count > 0)
        #expect(result.encoding == .utf8)
        #expect(elapsed < 3.0, "编码探测耗时 \(elapsed) 秒，超过 3 秒上限")
    }

    @Test("5MB 文本章节切分在 3 秒内完成")
    func chapterSplitOnLargeFile() {
        let text = makeLargeText(targetBytes: 5 * 1024 * 1024)

        let start = Date()
        let ranges = ChapterSplitter.split(text)
        let elapsed = Date().timeIntervalSince(start)

        #expect(ranges.count > 100)
        #expect(elapsed < 3.0, "章节切分耗时 \(elapsed) 秒，超过 3 秒上限")
    }

    @Test("5MB 文本探测只解码一次全文")
    func probeDoesNotDecodeWholeFile() {
        let text = makeLargeText(targetBytes: 5 * 1024 * 1024)
        let data = text.data(using: .utf8)!

        // probeEncoding 只应处理前 64KB，不应触碰全文
        let start = Date()
        let probed = TextEncodingDetector.probeEncoding(data: data)
        let elapsed = Date().timeIntervalSince(start)

        #expect(probed?.encoding == .utf8)
        #expect(elapsed < 0.5, "探测阶段耗时 \(elapsed) 秒，说明仍在解码全文")
    }

    @Test("切分结果在大文件上仍然首尾相接")
    func largeFileRangesContiguous() {
        let text = makeLargeText(targetBytes: 1024 * 1024)
        let ns = text as NSString
        let ranges = ChapterSplitter.split(text)

        var expectedStart = 0
        for range in ranges {
            #expect(range.range.location == expectedStart)
            expectedStart = range.range.location + range.range.length
        }
        #expect(expectedStart == ns.length)
    }

    @Test("单章分页 10 万字在 2 秒内完成")
    func paginateLargeChapter() {
        // 每行 28 个字符，5000 行 ≈ 14 万字符
        let text = String(repeating: "这是一段用于测试分页的正文内容，需要足够长才能产生多页。\n", count: 5000)
        #expect((text as NSString).length > 100_000)

        let profile = TypographyProfile(
            fontSize: 19,
            contentWidth: 340,
            contentHeight: 600
        )

        let start = Date()
        let result = Paginator.paginate(
            text: text,
            profile: profile,
            textColor: ReaderTheme.paper.text,
            chapterIndex: 0
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.pageCount > 10)
        #expect(elapsed < 2.0, "分页耗时 \(elapsed) 秒，超过 2 秒上限")
    }
}
