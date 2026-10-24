//
//  BookmarkEntity.swift
//  ModuReader
//
//  书签。一本书可以有多条，按阅读进度排序。
//

import Foundation
import SwiftData

@Model
final class BookmarkEntity {
    @Attribute(.unique) var id: UUID
    /// JSON 编码的 `Locator`。
    var locatorJSON: Data
    /// 全书进度 0...1。用于排序、换算页码、判断「当前页是否已加书签」。
    var totalProgression: Double
    /// 加书签时所在章节的标题。
    var chapterTitle: String
    var createdAt: Date
    var book: BookEntity?

    init(
        id: UUID = UUID(),
        locatorJSON: Data,
        totalProgression: Double,
        chapterTitle: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.locatorJSON = locatorJSON
        self.totalProgression = totalProgression
        self.chapterTitle = chapterTitle
        self.createdAt = createdAt
    }

    var locator: Locator? {
        try? JSONDecoder().decode(Locator.self, from: locatorJSON)
    }
}