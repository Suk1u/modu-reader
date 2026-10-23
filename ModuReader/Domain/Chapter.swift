//
//  Chapter.swift
//  ModuReader
//
//  章节模型。正文不进数据库，只存索引与文件引用。
//

import Foundation

/// 章节索引。正文存放在 `chapters/xxxx.txt`。
struct Chapter: Identifiable, Hashable, Sendable {
    /// 章节在书内的序号（0 起）。
    let id: Int
    var title: String
    /// 章节正文文件相对 `Books/<bookID>/` 的路径。
    var filePath: String
    /// 章节首字在全书中的 UTF-16 偏移。
    var globalStart: Int
    /// 章节字符数（UTF-16）。
    var characterCount: Int
    /// 在目录树中的层级。0 为顶层，1 为「卷」下的「章」，依此类推。
    var level: Int
    /// 是否为分组节点。
    ///
    /// 目录里带子项的条目（例如「第一卷」）本身通常不对应一段独立正文，
    /// 它只是子章节的容器。列表里要显示，但不参与「上一章 / 下一章」。
    var isGroup: Bool

    init(
        id: Int,
        title: String,
        filePath: String,
        globalStart: Int,
        characterCount: Int,
        level: Int = 0,
        isGroup: Bool = false
    ) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.globalStart = globalStart
        self.characterCount = characterCount
        self.level = level
        self.isGroup = isGroup
    }
}

/// 章节切分结果。`range` 为原文本中的 UTF-16 偏移。
struct ChapterRange: Hashable, Sendable {
    var title: String
    var range: NSRange

    init(title: String, range: NSRange) {
        self.title = title
        self.range = range
    }
}

/// 章节索引文件结构，落盘为 `index.json`。
struct ChapterIndex: Codable, Sendable {
    var chapters: [ChapterRecord]
    var totalCharacters: Int

    struct ChapterRecord: Codable, Sendable {
        var index: Int
        var title: String
        var file: String
        var globalStart: Int
        var characterCount: Int
    }
}
