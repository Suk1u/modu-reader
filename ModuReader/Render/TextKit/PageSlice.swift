//
//  PageSlice.swift
//  ModuReader
//
//  分页结果的不可变快照。跨线程只传这个类型。
//

import Foundation

/// 一页的字符区间。
///
/// 这是分页器与渲染器之间唯一的契约。`Sendable` 值类型，
/// 可以在任意队列之间安全传递（TextKit 对象则不能）。
struct PageSlice: Hashable, Sendable {
    /// 页内文本在章节中的 UTF-16 区间。
    var range: NSRange
    /// 该页在章节中的序号（0 起）。
    var pageIndex: Int

    init(range: NSRange, pageIndex: Int) {
        self.range = range
        self.pageIndex = pageIndex
    }
}

/// 一章的分页结果。
struct PaginatedChapter: Hashable, Sendable {
    /// 章节序号。
    var chapterIndex: Int
    /// 章节字符总数。
    var characterCount: Int
    /// 分页快照。
    var slices: [PageSlice]

    var pageCount: Int { slices.count }

    init(chapterIndex: Int, characterCount: Int, slices: [PageSlice]) {
        self.chapterIndex = chapterIndex
        self.characterCount = characterCount
        self.slices = slices
    }

    /// 找到包含指定字符偏移的页序号。
    ///
    /// - Parameter offset: 章节内 UTF-16 偏移。
    /// - Returns: 页序号；越界时返回最后一页（或 0）。
    func pageIndex(forCharacterOffset offset: Int) -> Int {
        guard !slices.isEmpty else { return 0 }
        guard offset > 0 else { return 0 }

        // 二分查找最后一个 range.location <= offset 的页
        var low = 0
        var high = slices.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if slices[mid].range.location <= offset {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// 某页在章节内的起始字符偏移。
    func characterOffset(forPageIndex index: Int) -> Int {
        guard !slices.isEmpty else { return 0 }
        let clamped = max(0, min(index, slices.count - 1))
        return slices[clamped].range.location
    }
}
