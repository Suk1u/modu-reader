//
//  ReadingProgress.swift
//  ModuReader
//

import Foundation

/// 一本书的阅读进度。
struct ReadingProgress: Codable, Hashable, Sendable {
    var bookID: UUID
    var locator: Locator
    /// 全书进度 0...1。
    var totalProgression: Double
    var updatedAt: Date
    var isFinished: Bool

    init(
        bookID: UUID,
        locator: Locator,
        totalProgression: Double,
        updatedAt: Date = Date(),
        isFinished: Bool = false
    ) {
        self.bookID = bookID
        self.locator = locator
        self.totalProgression = totalProgression
        self.updatedAt = updatedAt
        self.isFinished = isFinished
    }
}

/// 书籍的持久化元信息（与 SwiftData 实体解耦）。
struct BookDescriptor: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var author: String?
    var kind: PublicationKind
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
        isFinished: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.kind = kind
        self.formatExtension = formatExtension
        self.relativePath = relativePath
        self.coverPath = coverPath
        self.totalCharacters = totalCharacters
        self.chapterCount = chapterCount
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.detectedEncoding = detectedEncoding
        self.isFinished = isFinished
    }
}
