//
//  PageIndexCache.swift
//  ModuReader
//
//  分页缓存。把 [PageSlice] 按排版指纹落盘，避免每次打开都重新分页。
//

import Foundation

/// 分页缓存。
///
/// 目录布局：
/// ```
/// <Caches>/Pagination/<bookID>/<chapterID>/<typographyKey>.pageindex
/// ```
///
/// 键由 `TypographyProfile.cacheKey` 决定：字号、行距、页边距、
/// 页面尺寸任一变化都会得到不同的键，因此不会命中错误的分页结果。
struct PageIndexCache: Sendable {

    private let rootURL: URL
    /// 缓存总量上限（字节）。超过后按最后访问时间清理。
    private let sizeLimit: Int64

    init(sizeLimit: Int64 = 200 * 1024 * 1024) throws {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = caches.appendingPathComponent("Pagination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.rootURL = root
        self.sizeLimit = sizeLimit
    }

    /// 供测试注入自定义目录。
    init(rootURL: URL, sizeLimit: Int64 = 200 * 1024 * 1024) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        self.sizeLimit = sizeLimit
    }

    // MARK: - Read / Write

    /// 读取缓存的分页结果。
    ///
    /// - Returns: 命中时返回分页快照；未命中或数据损坏返回 nil。
    func load(bookID: UUID, chapterIndex: Int, profile: TypographyProfile) -> PaginatedChapter? {
        let url = fileURL(bookID: bookID, chapterIndex: chapterIndex, profile: profile)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredPagination.self, from: data) else {
            // 数据损坏：删除，避免每次都解析失败
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // 指纹不匹配视为未命中（防御：理论上文件名已保证一致）
        guard stored.cacheKey == profile.cacheKey else { return nil }

        let slices = stored.slices.map {
            PageSlice(
                range: NSRange(location: $0.location, length: $0.length),
                pageIndex: $0.pageIndex
            )
        }
        guard !slices.isEmpty else { return nil }

        // 触碰文件，更新最后访问时间供 LRU 清理
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )

        return PaginatedChapter(
            chapterIndex: chapterIndex,
            characterCount: stored.characterCount,
            slices: slices
        )
    }

    /// 写入分页结果。
    func store(_ chapter: PaginatedChapter, bookID: UUID, profile: TypographyProfile) {
        let url = fileURL(bookID: bookID, chapterIndex: chapter.chapterIndex, profile: profile)
        let stored = StoredPagination(
            cacheKey: profile.cacheKey,
            characterCount: chapter.characterCount,
            slices: chapter.slices.map {
                StoredPagination.Slice(
                    location: $0.range.location,
                    length: $0.range.length,
                    pageIndex: $0.pageIndex
                )
            }
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Maintenance

    /// 删除一本书的全部分页缓存。
    func removeAll(bookID: UUID) {
        let dir = rootURL.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// 清理缓存直到总量低于上限。
    ///
    /// 按文件修改时间从旧到新删除。修改时间在 `load` 时被刷新，
    /// 因此相当于 LRU。
    func evictIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int64, modified: Date)] = []
        var totalSize: Int64 = 0

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            files.append((url, size, modified))
            totalSize += size
        }

        guard totalSize > sizeLimit else { return }

        // 从最旧的开始删，直到降回上限的 80%
        let target = Int64(Double(sizeLimit) * 0.8)
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard totalSize > target else { break }
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                totalSize -= file.size
            }
        }
    }

    /// 当前缓存占用字节数（测试与诊断用）。
    func totalSize() -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Helpers

    private func fileURL(
        bookID: UUID,
        chapterIndex: Int,
        profile: TypographyProfile
    ) -> URL {
        rootURL
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent(String(format: "%04d", chapterIndex), isDirectory: true)
            .appendingPathComponent("\(profile.cacheKeyHash).pageindex")
    }
}

/// 落盘结构。用独立类型而非直接编码 `PaginatedChapter`，
/// 避免 `NSRange` 的跨平台编码差异。
private struct StoredPagination: Codable {
    var cacheKey: String
    var characterCount: Int
    var slices: [Slice]

    struct Slice: Codable {
        var location: Int
        var length: Int
        var pageIndex: Int
    }
}
