//
//  TextPublicationParser.swift
//  ModuReader
//
//  TXT / Markdown 解析：探测编码 → 归一化 → 切分章节 → 落盘。
//

import Foundation

/// TXT / Markdown 解析结果。
struct ParsedTextPublication: Sendable {
    var metadata: PublicationMetadata
    var chapters: [Chapter]
    var totalCharacters: Int
    var detectedEncodingName: String
}

/// 纯文本解析器。
///
/// 解析流程：
/// 1. 读取原始字节
/// 2. `TextEncodingDetector` 探测编码并解码
/// 3. 归一化换行与不可见字符
/// 4. `ChapterSplitter` 切分章节
/// 5. 章节正文逐文件写入，索引写入 `index.json`
/// 纯文本解析器。无状态，可跨队列使用。
struct TextPublicationParser: Sendable {

    private let fileStore: FileStore

    init(fileStore: FileStore) {
        self.fileStore = fileStore
    }

    /// 解析并落盘。
    ///
    /// - Parameters:
    ///   - url: 已复制到沙盒内的源文件。
    ///   - bookID: 书籍 UUID。
    ///   - displayTitle: 书名。为 nil 时从文件名推导。
    ///   - forcedEncoding: 用户手动指定的编码（为 nil 时自动探测）。
    func parse(
        url: URL,
        bookID: UUID,
        displayTitle: String? = nil,
        forcedEncoding: String.Encoding? = nil
    ) async throws -> ParsedTextPublication {
        let data = try Data(contentsOf: url)

        let decoded: EncodingDetectionResult
        if let forcedEncoding, let text = TextEncodingDetector.decode(data: data, using: forcedEncoding) {
            decoded = EncodingDetectionResult(
                encoding: forcedEncoding,
                displayName: TextEncodingDetector.manualOptions
                    .first(where: { $0.0 == forcedEncoding })?.1 ?? "自定义",
                text: text,
                hasReplacementCharacters: text.contains("\u{FFFD}"),
                isFallback: false
            )
        } else {
            decoded = TextEncodingDetector.detect(data: data)
        }

        let normalized = TextNormalizer.normalize(decoded.text)
        let ranges = ChapterSplitter.split(normalized)

        try fileStore.prepareBookDirectory(for: bookID)

        let ns = normalized as NSString
        var chapters: [Chapter] = []
        chapters.reserveCapacity(ranges.count)

        var globalStart = 0
        var records: [ChapterIndex.ChapterRecord] = []
        records.reserveCapacity(ranges.count)

        for (index, range) in ranges.enumerated() {
            let text = ns.substring(with: range.range)
            let fileName = String(format: "%04d.txt", index)
            try fileStore.writeChapter(text, for: bookID, fileName: fileName)

            let characterCount = (text as NSString).length
            let chapter = Chapter(
                id: index,
                title: range.title,
                filePath: fileName,
                globalStart: globalStart,
                characterCount: characterCount
            )
            chapters.append(chapter)
            records.append(
                ChapterIndex.ChapterRecord(
                    index: index,
                    title: range.title,
                    file: fileName,
                    globalStart: globalStart,
                    characterCount: characterCount
                )
            )
            globalStart += characterCount
        }

        let index = ChapterIndex(chapters: records, totalCharacters: globalStart)
        try fileStore.writeIndex(index, for: bookID)

        let title = displayTitle ?? Self.deriveTitle(from: url)
        let metadata = PublicationMetadata(
            title: title,
            language: "zh",
            wordCount: globalStart
        )
        try fileStore.writeMeta(metadata, for: bookID)

        return ParsedTextPublication(
            metadata: metadata,
            chapters: chapters,
            totalCharacters: globalStart,
            detectedEncodingName: decoded.displayName
        )
    }

    /// 从文件名推导书名。
    static func deriveTitle(from url: URL) -> String {
        deriveTitle(from: url.lastPathComponent)
    }

    /// 从文件名（含扩展名）推导书名：去掉扩展名，清理常见站点后缀。
    static func deriveTitle(from fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉常见的下载站后缀，如「书名_www.xxx.com」
        let separators = ["_www.", "（www.", "(www.", "[www."]
        for separator in separators {
            if let range = name.range(of: separator) {
                name = String(name[..<range.lowerBound])
            }
        }

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名" : name
    }
}

/// 文本归一化。
enum TextNormalizer {

    /// 统一换行、去除不可见字符、压缩连续空行。
    static func normalize(_ text: String) -> String {
        var result = text

        // 统一换行
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")

        // 去除零宽字符与 BOM
        let invisible: [Character] = ["\u{FEFF}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}"]
        result.removeAll(where: { invisible.contains($0) })

        // 不换行空格 → 普通空格
        result = result.replacingOccurrences(of: "\u{00A0}", with: " ")

        // 连续 3 个以上空行压缩为 2 个
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return result
    }
}
