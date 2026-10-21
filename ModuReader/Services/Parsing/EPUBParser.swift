//
//  EPUBParser.swift
//  ModuReader
//
//  EPUB 2/3 解析。
//
//  解析链路（EPUB 3.3 规范）：
//  1. META-INF/container.xml → 找到 OPF 路径
//  2. OPF（package document）→ metadata / manifest / spine
//  3. spine → 阅读顺序（每个 itemref 指向一个 XHTML）
//  4. nav.xhtml 或 NCX → 目录
//

import Foundation

/// EPUB 解析结果。
struct ParsedEPUB {
    var metadata: PublicationMetadata
    var chapters: [Chapter]
    var totalCharacters: Int
    var isFixedLayout: Bool
    var readingProgression: ReadingProgression
    /// 解压目录（章节 XHTML 与资源所在处）。
    var extractedDirectory: URL
}

/// EPUB 解析器。
struct EPUBParser: Sendable {

    private let fileStore: FileStore

    init(fileStore: FileStore) {
        self.fileStore = fileStore
    }

    /// 解析并落盘。
    ///
    /// 流程：解压到 `Books/<bookID>/extracted/` → 读 container → 读 OPF →
    /// 提取 spine 顺序 → 每个 XHTML 转成纯文本章节。
    func parse(url: URL, bookID: UUID) async throws -> ParsedEPUB {
        try fileStore.prepareBookDirectory(for: bookID)

        let extracted = fileStore.bookDirectory(for: bookID)
            .appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)

        // 1. 解压
        try Self.extract(archiveURL: url, to: extracted)

        // 2. container.xml → OPF 路径
        let containerURL = extracted.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw EPUBError.missingContainer
        }
        let opfPath = try Self.parseContainer(xml: Data(contentsOf: containerURL))
        let opfURL = extracted.appendingPathComponent(opfPath)
        guard FileManager.default.fileExists(atPath: opfURL.path) else {
            throw EPUBError.missingPackageDocument(opfPath)
        }

        // 3. 解析 OPF
        let package = try Self.parsePackage(xml: Data(contentsOf: opfURL))
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        // 4. 逐个 spine 项转成章节
        var chapters: [Chapter] = []
        var records: [ChapterIndex.ChapterRecord] = []
        var globalStart = 0
        var totalCharacters = 0

        for (index, itemRef) in package.spine.enumerated() {
            guard let manifestItem = package.manifest[itemRef.idref] else { continue }

            let href = manifestItem.href
            let resourcePath = opfDirectory.isEmpty
                ? href
                : "\(opfDirectory)/\(href)"
            let resourceURL = extracted.appendingPathComponent(resourcePath)

            guard FileManager.default.fileExists(atPath: resourceURL.path) else {
                Diagnostics.log("EPUB: 跳过缺失资源 \(resourcePath)")
                continue
            }

            let text: String
            do {
                text = try Self.extractText(fromXHTML: Data(contentsOf: resourceURL))
            } catch {
                Diagnostics.log("EPUB: 解析 \(resourcePath) 失败 \(error.localizedDescription)")
                continue
            }

            // 空章节也保留，否则章节序号会与目录错位
            let title = package.tocTitles[resourcePath]
                ?? package.tocTitles[href]
                ?? "第 \(index + 1) 章"

            let fileName = String(format: "%04d.txt", chapters.count)
            try fileStore.writeChapter(text, for: bookID, fileName: fileName)

            let characterCount = (text as NSString).length
            chapters.append(
                Chapter(
                    id: chapters.count,
                    title: title,
                    filePath: fileName,
                    globalStart: globalStart,
                    characterCount: characterCount
                )
            )
            records.append(
                ChapterIndex.ChapterRecord(
                    index: chapters.count - 1,
                    title: title,
                    file: fileName,
                    globalStart: globalStart,
                    characterCount: characterCount
                )
            )
            globalStart += characterCount
            totalCharacters = globalStart
        }

        guard !chapters.isEmpty else {
            throw EPUBError.noReadableContent
        }

        try fileStore.writeIndex(
            ChapterIndex(chapters: records, totalCharacters: totalCharacters),
            for: bookID
        )

        let metadata = PublicationMetadata(
            title: package.title ?? "未命名",
            author: package.author,
            publisher: package.publisher,
            language: package.language,
            identifier: package.identifier,
            wordCount: totalCharacters
        )
        try fileStore.writeMeta(metadata, for: bookID)

        return ParsedEPUB(
            metadata: metadata,
            chapters: chapters,
            totalCharacters: totalCharacters,
            isFixedLayout: package.isFixedLayout,
            readingProgression: package.readingProgression,
            extractedDirectory: extracted
        )
    }

    // MARK: - Extraction

    /// 解压 EPUB 到指定目录。
    ///
    /// 复用 `ZipArchive`，并做 Zip Slip 防护。
    static func extract(archiveURL: URL, to destination: URL) throws {
        let archive = try ZipArchive(url: archiveURL)
        let entries = try archive.entries()

        let destinationPath = destination.standardizedFileURL.path

        for entry in entries {
            guard !entry.isDirectory else { continue }
            // 跳过 macOS 元数据
            if entry.path.hasPrefix("__MACOSX/") || entry.path.hasSuffix(".DS_Store") {
                continue
            }

            let targetURL = destination.appendingPathComponent(entry.path).standardizedFileURL
            // Zip Slip 防护：目标必须在解压目录内
            guard targetURL.path.hasPrefix(destinationPath) else {
                Diagnostics.log("EPUB: 拒绝越界路径 \(entry.path)")
                continue
            }

            let data = try archive.data(for: entry)
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: targetURL, options: .atomic)
        }
    }

    // MARK: - container.xml

    private static func parseContainer(xml: Data) throws -> String {
        let parser = XMLParser(data: xml)
        let delegate = ContainerDelegate()
        parser.delegate = delegate
        guard parser.parse(), let path = delegate.rootfilePath else {
            throw EPUBError.invalidContainer
        }
        return path
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        var rootfilePath: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "rootfile" {
                rootfilePath = attributeDict["full-path"]
            }
        }
    }

    // MARK: - OPF

    struct OPFPackage {
        var title: String?
        var author: String?
        var publisher: String?
        var language: String?
        var identifier: String?
        var manifest: [String: ManifestItem]
        var spine: [SpineItemRef]
        var tocTitles: [String: String]
        var isFixedLayout: Bool
        var readingProgression: ReadingProgression

        struct ManifestItem {
            var id: String
            var href: String
            var mediaType: String
            var properties: String
        }

        struct SpineItemRef {
            var idref: String
            var linear: Bool
        }
    }

    private static func parsePackage(xml: Data) throws -> OPFPackage {
        let parser = XMLParser(data: xml)
        // 开启命名空间处理：OPF 里 dc:title 等前缀需要被正确识别。
        // 关闭时 elementName 会带上前缀，容易漏匹配。
        parser.shouldProcessNamespaces = false
        let delegate = PackageDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw EPUBError.invalidPackageDocument
        }
        return delegate.package
    }

    private final class PackageDelegate: NSObject, XMLParserDelegate {
        var package = OPFPackage(
            manifest: [:],
            spine: [],
            tocTitles: [:],
            isFixedLayout: false,
            readingProgression: .ltr
        )

        private var tocHref: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "item":
                guard let id = attributeDict["id"],
                      let href = attributeDict["href"] else { return }
                package.manifest[id] = OPFPackage.ManifestItem(
                    id: id,
                    href: href.removingPercentEncoding ?? href,
                    mediaType: attributeDict["media-type"] ?? "",
                    properties: attributeDict["properties"] ?? ""
                )

            case "itemref":
                guard let idref = attributeDict["idref"] else { return }
                let linear = attributeDict["linear"] != "no"
                package.spine.append(
                    OPFPackage.SpineItemRef(idref: idref, linear: linear)
                )

            case "meta":
                // EPUB 3：<meta property="rendition:layout">pre-paginated</meta>
                // EPUB 2：<meta name="fixed-layout" content="true"/>
                if attributeDict["name"] == "fixed-layout",
                   attributeDict["content"] == "true" {
                    package.isFixedLayout = true
                }
                if attributeDict["property"] == "rendition:layout" {
                    pendingLayoutValue = true
                }

            case "spine":
                if let direction = attributeDict["page-progression-direction"] {
                    package.readingProgression = direction == "rtl" ? .rtl : .ltr
                }

            case "title":
                if package.title == nil {
                    pendingTitle = true
                }

            case "creator":
                if package.author == nil {
                    pendingAuthor = true
                }

            case "publisher":
                if package.publisher == nil {
                    pendingPublisher = true
                }

            case "dc:language", "language":
                if package.language == nil {
                    pendingLanguage = true
                }

            case "dc:identifier", "identifier":
                if package.identifier == nil {
                    pendingIdentifier = true
                }

            case "navPoint":
                // NCX 目录：id 指向 content src
                break

            case "content":
                if let src = attributeDict["src"] {
                    tocHref = src
                }

            case "text":
                pendingTOCLabel = true

            default:
                break
            }
        }

        private var pendingTitle = false
        private var pendingAuthor = false
        private var pendingPublisher = false
        private var pendingLanguage = false
        private var pendingIdentifier = false
        private var pendingTOCLabel = false
        private var currentTOCLabel = ""
        var pendingLayoutValue = false

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if pendingTitle {
                package.title = (package.title ?? "") + string
            }
            if pendingAuthor {
                package.author = (package.author ?? "") + string
            }
            if pendingPublisher {
                package.publisher = (package.publisher ?? "") + string
            }
            if pendingLanguage {
                package.language = (package.language ?? "") + string
            }
            if pendingIdentifier {
                package.identifier = (package.identifier ?? "") + string
            }
            if pendingTOCLabel {
                currentTOCLabel += string
            }
            if pendingLayoutValue {
                let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "pre-paginated" {
                    package.isFixedLayout = true
                }
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "title":
                pendingTitle = false
                package.title = package.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "creator":
                pendingAuthor = false
                package.author = package.author?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "publisher":
                pendingPublisher = false
                package.publisher = package.publisher?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "dc:language", "language":
                pendingLanguage = false
                package.language = package.language?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "dc:identifier", "identifier":
                pendingIdentifier = false
                package.identifier = package.identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "text":
                pendingTOCLabel = false
                if let href = tocHref {
                    let label = currentTOCLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !label.isEmpty {
                        package.tocTitles[href] = label
                    }
                }
                currentTOCLabel = ""
            case "meta":
                pendingLayoutValue = false
            case "content":
                // 保持 tocHref，等 text 元素出现
                break
            default:
                break
            }
        }
    }

    // MARK: - XHTML → 纯文本

    /// 把 XHTML 转为纯文本。
    ///
    /// 只提取语义结构：段落之间用空行分隔，标题单独成行。
    /// 丢弃全部标签、脚本、样式、注释。
    static func extractText(fromXHTML data: Data) throws -> String {
        let parser = XMLParser(data: data)
        let delegate = XHTMLTextDelegate()
        parser.delegate = delegate

        // XHTML 可能不是严格合法的 XML（HTML 实体未声明等）。
        // 解析失败时退化为正则剥离标签，保证至少能读到内容。
        if parser.parse() {
            return delegate.finish()
        }

        Diagnostics.log("EPUB: XHTML 严格解析失败，退化为正则剥离")
        let raw = String(decoding: data, as: UTF8.self)
        return fallbackStripHTML(raw)
    }

    private final class XHTMLTextDelegate: NSObject, XMLParserDelegate {
        private var output: [String] = []
        private var currentParagraph = ""
        private var skipDepth = 0
        private var blockDepth = 0

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()

            if ["script", "style", "head", "title"].contains(name) {
                skipDepth += 1
                return
            }

            switch name {
            case "p", "div", "section", "article", "blockquote", "li",
                 "h1", "h2", "h3", "h4", "h5", "h6", "br", "tr":
                flushParagraph()
                blockDepth += 1
            case "td", "th":
                currentParagraph += " "
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            currentParagraph += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let name = elementName.lowercased()

            if ["script", "style", "head", "title"].contains(name) {
                skipDepth = max(0, skipDepth - 1)
                return
            }

            switch name {
            case "p", "div", "section", "article", "blockquote", "li",
                 "h1", "h2", "h3", "h4", "h5", "h6", "br", "tr":
                flushParagraph()
                blockDepth = max(0, blockDepth - 1)
            default:
                break
            }
        }

        private func flushParagraph() {
            let text = currentParagraph
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                output.append(text)
            }
            currentParagraph = ""
        }

        func finish() -> String {
            flushParagraph()
            return output.joined(separator: "\n\n")
        }
    }

    private static func fallbackStripHTML(_ html: String) -> String {
        var text = html
        // 去掉 script / style 整块
        for tag in ["script", "style", "head"] {
            let pattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: ""
                )
            }
        }
        // 块级标签换成换行
        for tag in ["p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li"] {
            text = text.replacingOccurrences(
                of: "</?\(tag)[^>]*>",
                with: "\n\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // 去掉剩余标签
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: [.regularExpression]
        )
        // 解码常见实体
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        // 压缩空行
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum EPUBError: LocalizedError {
    case missingContainer
    case invalidContainer
    case missingPackageDocument(String)
    case invalidPackageDocument
    case noReadableContent

    var errorDescription: String? {
        switch self {
        case .missingContainer:
            "EPUB 缺少 META-INF/container.xml，文件可能不是有效的 EPUB。"
        case .invalidContainer:
            "EPUB 的 container.xml 无法解析。"
        case .missingPackageDocument(let path):
            "EPUB 缺少包文档：\(path)"
        case .invalidPackageDocument:
            "EPUB 的包文档（OPF）无法解析。"
        case .noReadableContent:
            "EPUB 内没有可读的正文内容。"
        }
    }
}
