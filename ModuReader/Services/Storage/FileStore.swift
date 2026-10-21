//
//  FileStore.swift
//  ModuReader
//
//  沙盒文件布局。正文落地为文件，数据库只存索引。
//

import Foundation

/// 沙盒文件存储。
///
/// 目录布局：
/// ```
/// <Application Support>/
/// └── Books/
///     └── <bookID>/
///         ├── source.txt
///         ├── meta.json
///         ├── cover.jpg
///         ├── chapters/
///         │   ├── 0000.txt
///         │   └── ...
///         └── index.json
/// ```
struct FileStore: Sendable {
    let rootURL: URL

    /// 使用 Application Support 下的 Books 目录。
    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let books = support.appendingPathComponent("Books", isDirectory: true)
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        try FileStore.excludeFromBackup(books)
        self.rootURL = books
    }

    /// 供测试注入自定义根目录。
    init(rootURL: URL) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
    }

    // MARK: - Paths

    /// 一本书的根目录。
    func bookDirectory(for bookID: UUID) -> URL {
        rootURL.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    /// 章节目录。
    func chaptersDirectory(for bookID: UUID) -> URL {
        bookDirectory(for: bookID).appendingPathComponent("chapters", isDirectory: true)
    }

    /// 章节文件路径。
    func chapterFileURL(for bookID: UUID, fileName: String) -> URL {
        chaptersDirectory(for: bookID).appendingPathComponent(fileName)
    }

    /// 索引文件路径。
    func indexURL(for bookID: UUID) -> URL {
        bookDirectory(for: bookID).appendingPathComponent("index.json")
    }

    /// 元信息文件路径。
    func metaURL(for bookID: UUID) -> URL {
        bookDirectory(for: bookID).appendingPathComponent("meta.json")
    }

    // MARK: - Lifecycle

    /// 为一本新书创建目录结构。
    func prepareBookDirectory(for bookID: UUID) throws {
        try FileManager.default.createDirectory(
            at: chaptersDirectory(for: bookID),
            withIntermediateDirectories: true
        )
        try FileStore.excludeFromBackup(bookDirectory(for: bookID))
    }

    /// 删除一本书的所有文件。
    func deleteBook(_ bookID: UUID) throws {
        let dir = bookDirectory(for: bookID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - Read / Write

    /// 写入章节正文（UTF-8）。
    func writeChapter(_ text: String, for bookID: UUID, fileName: String) throws {
        let url = chapterFileURL(for: bookID, fileName: fileName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = text.data(using: .utf8) else {
            throw FileStoreError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    /// 读取章节正文。
    func readChapter(for bookID: UUID, fileName: String) throws -> String {
        let url = chapterFileURL(for: bookID, fileName: fileName)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FileStoreError.decodingFailed
        }
        return text
    }

    /// 写入索引。
    func writeIndex(_ index: ChapterIndex, for bookID: UUID) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL(for: bookID), options: .atomic)
    }

    /// 读取索引。
    func readIndex(for bookID: UUID) throws -> ChapterIndex {
        let data = try Data(contentsOf: indexURL(for: bookID))
        return try JSONDecoder().decode(ChapterIndex.self, from: data)
    }

    /// 写入元信息。
    func writeMeta(_ metadata: PublicationMetadata, for bookID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metaURL(for: bookID), options: .atomic)
    }

    /// 读取元信息。
    func readMeta(for bookID: UUID) throws -> PublicationMetadata {
        let data = try Data(contentsOf: metaURL(for: bookID))
        return try JSONDecoder().decode(PublicationMetadata.self, from: data)
    }

    // MARK: - Backup exclusion

    /// 排除 iCloud 备份，避免用户备份空间被书籍撑爆。
    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

enum FileStoreError: Error, LocalizedError {
    case encodingFailed
    case decodingFailed
    case missingBook

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "文本编码失败。"
        case .decodingFailed: "文本解码失败。"
        case .missingBook: "书籍不存在。"
        }
    }
}
