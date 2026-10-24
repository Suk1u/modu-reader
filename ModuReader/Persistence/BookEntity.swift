//
//  BookEntity.swift
//  ModuReader
//
//  SwiftData 实体。正文不进数据库，只存索引与元数据。
//

import Foundation
import SwiftData

/// 书籍实体。
@Model
final class BookEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String?
    var kindRaw: String
    var formatExtension: String
    /// 相对 `Books/` 的目录名。
    var relativePath: String
    var coverPath: String?
    var totalCharacters: Int
    var chapterCount: Int
    var addedAt: Date
    var lastOpenedAt: Date?
    var detectedEncoding: String?
    var isFinished: Bool
    /// 该书的阅读方式（paged / scroll）。nil 表示跟随全局默认。
    var readingModeRaw: String?

    @Relationship(deleteRule: .cascade, inverse: \ProgressEntity.book)
    var progress: ProgressEntity?

    @Relationship(deleteRule: .cascade, inverse: \BookmarkEntity.book)
    var bookmarks: [BookmarkEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \HighlightEntity.book)
    var highlights: [HighlightEntity] = []

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        kind: PublicationKind,
        formatExtension: String,
        relativePath: String,
        coverPath: String? = nil,
        totalCharacters: Int = 0,
        chapterCount: Int = 0,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        detectedEncoding: String? = nil,
        isFinished: Bool = false,
        readingModeRaw: String? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.kindRaw = kind.rawValue
        self.formatExtension = formatExtension
        self.relativePath = relativePath
        self.coverPath = coverPath
        self.totalCharacters = totalCharacters
        self.chapterCount = chapterCount
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.detectedEncoding = detectedEncoding
        self.isFinished = isFinished
        self.readingModeRaw = readingModeRaw
    }

    var kind: PublicationKind {
        get { PublicationKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    /// 转换为与持久化无关的描述符。
    var descriptor: BookDescriptor {
        BookDescriptor(
            id: id,
            title: title,
            author: author,
            kind: kind,
            formatExtension: formatExtension,
            relativePath: relativePath,
            coverPath: coverPath,
            totalCharacters: totalCharacters,
            chapterCount: chapterCount,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            detectedEncoding: detectedEncoding,
            isFinished: isFinished
        )
    }
}

/// 阅读进度实体。
@Model
final class ProgressEntity {
    /// JSON 编码的 `Locator`。
    var locatorJSON: Data
    var totalProgression: Double
    var updatedAt: Date
    /// JSON 编码的书签位置。nil 表示本书没有书签。
    ///
    /// 单书单书签：与顶栏那个「有 / 无」按钮一一对应，
    /// 收藏列表等需求再单独建实体。
    var bookmarkJSON: Data?
    var book: BookEntity?

    init(
        locatorJSON: Data,
        totalProgression: Double,
        updatedAt: Date = Date(),
        bookmarkJSON: Data? = nil
    ) {
        self.locatorJSON = locatorJSON
        self.totalProgression = totalProgression
        self.updatedAt = updatedAt
        self.bookmarkJSON = bookmarkJSON
    }

    /// 解码 Locator。失败时返回 nil（不崩溃）。
    var locator: Locator? {
        try? JSONDecoder().decode(Locator.self, from: locatorJSON)
    }

    /// 更新为新的 Locator。
    func update(with locator: Locator, totalProgression: Double) {
        guard let data = try? JSONEncoder().encode(locator) else { return }
        self.locatorJSON = data
        self.totalProgression = totalProgression
        self.updatedAt = Date()
    }
}
