//
//  Publication.swift
//  ModuReader
//
//  与具体文件格式无关的书籍抽象。
//

import Foundation

/// 一本书的抽象。与具体格式无关。
struct Publication: Identifiable, Hashable, Sendable {
    let id: UUID
    var metadata: PublicationMetadata
    var kind: PublicationKind
    /// 章节 / 页面资源，顺序即阅读顺序。
    var readingOrder: [Resource]
    var tableOfContents: [TOCItem]
    var layout: LayoutStyle
    var readingProgression: ReadingProgression
    /// 资源根目录（沙盒内）。
    var baseURL: URL

    init(
        id: UUID = UUID(),
        metadata: PublicationMetadata,
        kind: PublicationKind,
        readingOrder: [Resource],
        tableOfContents: [TOCItem] = [],
        layout: LayoutStyle,
        readingProgression: ReadingProgression = .ltr,
        baseURL: URL
    ) {
        self.id = id
        self.metadata = metadata
        self.kind = kind
        self.readingOrder = readingOrder
        self.tableOfContents = tableOfContents
        self.layout = layout
        self.readingProgression = readingProgression
        self.baseURL = baseURL
    }
}

/// 内容类型。决定路由到哪个渲染引擎。
enum PublicationKind: String, Codable, Hashable, Sendable {
    /// 纯文本：TXT / Markdown。
    case text
    /// EPUB 可重排。
    case epubReflowable
    /// EPUB 固定布局。
    case epubFixedLayout
    /// 漫画：CBZ / CBR / 图片文件夹。
    case comic
    /// PDF 文档。
    case pdf
    /// 长条漫（竖向连续）。
    case webtoon
}

/// 排版方式。
enum LayoutStyle: String, Codable, Hashable, Sendable {
    /// 文字重排。
    case reflowable
    /// 固定版式（图像 / 预排版）。
    case fixed
}

/// 阅读方向。
enum ReadingProgression: String, Codable, Hashable, Sendable {
    case ltr
    case rtl
}

struct PublicationMetadata: Codable, Hashable, Sendable {
    var title: String
    var author: String?
    var publisher: String?
    var language: String?
    var coverURL: URL?
    var identifier: String?
    var summary: String?
    var tags: [String]
    var wordCount: Int?

    init(
        title: String,
        author: String? = nil,
        publisher: String? = nil,
        language: String? = nil,
        coverURL: URL? = nil,
        identifier: String? = nil,
        summary: String? = nil,
        tags: [String] = [],
        wordCount: Int? = nil
    ) {
        self.title = title
        self.author = author
        self.publisher = publisher
        self.language = language
        self.coverURL = coverURL
        self.identifier = identifier
        self.summary = summary
        self.tags = tags
        self.wordCount = wordCount
    }
}

/// 一个可寻址资源（一个章节，或一页图）。
struct Resource: Identifiable, Hashable, Sendable {
    /// 相对 href，如 "chapters/0001.txt"。
    let id: String
    var href: String
    var mediaType: String
    var title: String?
    var byteSize: Int64?

    init(
        id: String? = nil,
        href: String,
        mediaType: String = "text/plain",
        title: String? = nil,
        byteSize: Int64? = nil
    ) {
        self.id = id ?? href
        self.href = href
        self.mediaType = mediaType
        self.title = title
        self.byteSize = byteSize
    }
}

/// 目录项。
struct TOCItem: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    /// 指向的 Resource.href。
    var href: String
    /// 章节在 readingOrder 中的索引。
    var chapterIndex: Int
    /// 层级，0 为顶层。
    var depth: Int
    var children: [TOCItem]

    init(
        id: String? = nil,
        title: String,
        href: String,
        chapterIndex: Int,
        depth: Int = 0,
        children: [TOCItem] = []
    ) {
        self.id = id ?? "\(chapterIndex)-\(href)"
        self.title = title
        self.href = href
        self.chapterIndex = chapterIndex
        self.depth = depth
        self.children = children
    }
}
