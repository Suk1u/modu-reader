//
//  HighlightEntity.swift
//  ModuReader
//
//  高亮标记。当前以「页」为粒度记录位置。
//

import Foundation
import SwiftData

@Model
final class HighlightEntity {
    @Attribute(.unique) var id: UUID
    var locatorJSON: Data
    var totalProgression: Double
    var chapterTitle: String
    /// 标记时抓取的正文片段，作为列表里的辨识内容。
    var excerpt: String
    /// 高亮颜色 `#RRGGBB`。nil 用默认暖黄。
    var tintHex: String?
    /// 是否用下划线代替底色。
    var underline: Bool?
    var createdAt: Date
    var book: BookEntity?

    init(
        id: UUID = UUID(),
        locatorJSON: Data,
        totalProgression: Double,
        chapterTitle: String,
        excerpt: String,
        tintHex: String? = nil,
        underline: Bool? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.locatorJSON = locatorJSON
        self.totalProgression = totalProgression
        self.chapterTitle = chapterTitle
        self.excerpt = excerpt
        self.tintHex = tintHex
        self.underline = underline
        self.createdAt = createdAt
    }

    var locator: Locator? {
        try? JSONDecoder().decode(Locator.self, from: locatorJSON)
    }
}