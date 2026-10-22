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
    /// 封面在书籍目录内的文件名。nil 表示没有封面。
    var coverFileName: String?
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
        var package = try Self.parsePackage(xml: Data(contentsOf: opfURL))
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        // 3.1 解析 NCX / nav 得到真实目录标题
        package.tocTitles = Self.loadTableOfContents(
            package: package,
            opfDirectory: opfDirectory,
            extracted: extracted
        )
        Diagnostics.log("EPUB: 目录项 \(package.tocTitles.count) 条")

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
                var raw = try Self.extractText(fromXHTML: Data(contentsOf: resourceURL))
                // 把图片相对路径改写为解压目录内的绝对路径，
                // 这样渲染层无需知道 OPF 结构。
                raw = Self.resolveImagePaths(
                    in: raw,
                    chapterDirectory: (resourcePath as NSString).deletingLastPathComponent,
                    extractedRoot: extracted
                )
                text = raw
            } catch {
                Diagnostics.log("EPUB: 解析 \(resourcePath) 失败 \(error.localizedDescription)")
                continue
            }

            // 空章节也保留，否则章节序号会与目录错位。
            // 标题按「规范化相对路径」查找（去掉 ./、解码百分号）。
            let normalizedResource = Self.normalizePath(resourcePath)
            let normalizedHref = Self.normalizePath(href)
            let title = package.tocTitles[normalizedResource]
                ?? package.tocTitles[normalizedHref]
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
        // 提取封面并复制到书籍目录
        var coverPath: String?
        if let coverSource = Self.resolveCoverSource(
            package: package,
            opfDirectory: opfDirectory,
            extracted: extracted
        ) {
            let target = fileStore.bookDirectory(for: bookID)
                .appendingPathComponent("cover\(coverSource.pathExtension.isEmpty ? "jpg" : "." + coverSource.pathExtension)")
            if (try? FileManager.default.copyItem(at: coverSource, to: target)) != nil {
                coverPath = target.lastPathComponent
                Diagnostics.log("EPUB: 封面已提取 \(coverPath ?? "")")
            }
        }
        if coverPath == nil {
            Diagnostics.log("EPUB: 未找到封面")
        }

        try fileStore.writeMeta(metadata, for: bookID)

        return ParsedEPUB(
            metadata: metadata,
            chapters: chapters,
            totalCharacters: totalCharacters,
            isFixedLayout: package.isFixedLayout,
            readingProgression: package.readingProgression,
            extractedDirectory: extracted,
            coverFileName: coverPath
        )
    }

    // MARK: - 目录

    /// 规范化相对路径。
    ///
    /// 统一处理：去掉 "./" 前缀、合并重复斜杠、解码百分号编码、
    /// 拆分 fragment（#section）。
    static func normalizePath(_ path: String) -> String {
        var result = path
        // 去掉 fragment
        if let hash = result.firstIndex(of: "#") {
            result = String(result[..<hash])
        }
        // 解码百分号
        result = result.removingPercentEncoding ?? result
        // 去掉 "./"
        while result.hasPrefix("./") {
            result.removeFirst(2)
        }
        // 合并重复斜杠
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        // 去掉开头的 /
        while result.hasPrefix("/") {
            result.removeFirst()
        }
        return result
    }

    /// 解析 NCX 或 EPUB 3 nav 文档，得到「资源路径 → 章节标题」映射。
    ///
    /// 支持两种格式：
    /// - EPUB 2：`toc.ncx` 的 `<navPoint><navLabel><text>标题</text></navLabel><content src="..."/></navPoint>`
    /// - EPUB 3：`nav.xhtml` 的 `<nav epub:type="toc"><ol><li><a href="...">标题</a></li></ol></nav>`
    static func loadTableOfContents(
        package: OPFPackage,
        opfDirectory: String,
        extracted: URL
    ) -> [String: String] {
        // 找到 NCX 或 nav 文档
        var tocHref: String?
        for item in package.manifest.values {
            let mediaType = item.mediaType.lowercased()
            let properties = item.properties.lowercased()
            if mediaType.contains("dtbncx") || item.href.lowercased().hasSuffix(".ncx") {
                tocHref = item.href
                break
            }
            if properties.contains("nav") {
                tocHref = item.href
                break
            }
        }

        guard let tocHref else {
            Diagnostics.log("EPUB: 未找到 NCX / nav 文档")
            return [:]
        }

        let tocPath = opfDirectory.isEmpty ? tocHref : "\(opfDirectory)/\(tocHref)"
        let tocURL = extracted.appendingPathComponent(tocPath)
        guard let data = try? Data(contentsOf: tocURL) else {
            Diagnostics.log("EPUB: 目录文件读取失败 \(tocPath)")
            return [:]
        }

        // 目录文件所在目录，用于把 src 解析为相对解压根的路径
        let tocDirectory = (tocPath as NSString).deletingLastPathComponent

        let parser = XMLParser(data: data)
        let delegate = TOCDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            Diagnostics.log("EPUB: 目录文件解析失败 \(tocPath)")
            return [:]
        }

        // 把 src 转换为相对解压根的规范化路径
        var result: [String: String] = [:]
        for entry in delegate.entries {
            let raw = normalizePath(entry.href)
            let combined = tocDirectory.isEmpty ? raw : "\(tocDirectory)/\(raw)"
            result[normalizePath(combined)] = entry.title
            // 同时存一份相对于 OPF 目录的路径，兼容 spine 里 href 的写法
            result[raw] = entry.title
        }
        return result
    }

    /// NCX / nav 解析委托。
    private final class TOCDelegate: NSObject, XMLParserDelegate {
        struct Entry {
            var href: String
            var title: String
        }

        var entries: [Entry] = []

        private var pendingHref: String?
        private var collectingLabel = false
        private var currentLabel = ""
        private var labelDepth = 0

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()

            switch name {
            case "content":
                // NCX
                if let src = attributeDict["src"] {
                    pendingHref = src
                }
            case "a":
                // EPUB 3 nav
                if let href = attributeDict["href"] {
                    pendingHref = href
                }
            case "text", "span":
                if pendingHref != nil {
                    collectingLabel = true
                    labelDepth += 1
                    currentLabel = ""
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collectingLabel {
                currentLabel += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let name = elementName.lowercased()

            switch name {
            case "text", "span":
                if collectingLabel {
                    labelDepth -= 1
                    if labelDepth <= 0 {
                        collectingLabel = false
                        let title = currentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let href = pendingHref, !title.isEmpty {
                            entries.append(Entry(href: href, title: title))
                        }
                        pendingHref = nil
                        currentLabel = ""
                    }
                }
            case "navpoint", "li", "a":
                // 一个目录项结束
                if !collectingLabel, let href = pendingHref {
                    // nav 的 <a> 内文字可能没被 span 包裹
                    let title = currentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        entries.append(Entry(href: href, title: title))
                    }
                    pendingHref = nil
                    currentLabel = ""
                }
            default:
                break
            }
        }
    }

    // MARK: - Cover

    /// 定位封面图片文件。
    ///
    /// 优先顺序：
    /// 1. EPUB 3 的 properties="cover-image"
    /// 2. EPUB 2 的 <meta name="cover" content="id"> → manifest[id].href
    /// 3. 文件名含 cover 的第一张图片
    static func resolveCoverSource(
        package: OPFPackage,
        opfDirectory: String,
        extracted: URL
    ) -> URL? {
        func url(for href: String) -> URL? {
            let relative = opfDirectory.isEmpty ? href : "\(opfDirectory)/\(href)"
            let candidate = extracted.appendingPathComponent(relative).standardizedFileURL
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            return candidate
        }

        if let href = package.coverHref, let found = url(for: href) {
            return found
        }

        if let id = package.coverID,
           let item = package.manifest[id],
           let found = url(for: item.href) {
            return found
        }

        // 兜底：按文件名猜
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]
        for item in package.manifest.values {
            let ext = (item.href as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            guard item.href.lowercased().contains("cover") else { continue }
            if let found = url(for: item.href) {
                return found
            }
        }

        return nil
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
        /// EPUB 2 的 <meta name="cover" content="id"> 指向的图片 id。
        var coverID: String?
        /// EPUB 3 的 properties="cover-image" 图片 href。
        var coverHref: String?

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
                let properties = attributeDict["properties"] ?? ""
                let normalizedHref = href.removingPercentEncoding ?? href
                package.manifest[id] = OPFPackage.ManifestItem(
                    id: id,
                    href: normalizedHref,
                    mediaType: attributeDict["media-type"] ?? "",
                    properties: properties
                )
                // EPUB 3 封面：properties="cover-image"
                if properties.split(separator: " ").contains("cover-image") {
                    package.coverHref = normalizedHref
                }

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
                // EPUB 2 封面：<meta name="cover" content="cover-image-id"/>
                if attributeDict["name"] == "cover",
                   let content = attributeDict["content"] {
                    package.coverID = content
                }
                if attributeDict["property"] == "rendition:layout" {
                    pendingLayoutValue = true
                }

            case "spine":
                if let direction = attributeDict["page-progression-direction"] {
                    package.readingProgression = direction == "rtl" ? .rtl : .ltr
                }

            case "dc:title", "title":
                if package.title == nil {
                    pendingTitle = true
                }

            case "dc:creator", "creator":
                if package.author == nil {
                    pendingAuthor = true
                }

            case "dc:publisher", "publisher":
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
            case "dc:title", "title":
                pendingTitle = false
                package.title = package.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "dc:creator", "creator":
                pendingAuthor = false
                package.author = package.author?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "dc:publisher", "publisher":
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
            case "img":
                // 图片用占位标记保留，渲染层据此插入图像。
                //
                // 为什么不用 NSTextAttachment：
                // 分页器基于 CoreText 的 CTFramesetter 计算字符区间，
                // attachment 会参与排版计算但不占据可预测的字符位置，
                // 导致分页边界与渲染错位。用纯文本标记则完全可控。
                if let src = attributeDict["src"], !src.isEmpty {
                    flushParagraph()
                    output.append(EPUBParser.imageMarker(for: src))
                }
            case "image":
                // SVG 里的 <image xlink:href="...">
                let href = attributeDict["xlink:href"]
                    ?? attributeDict["href"]
                if let href, !href.isEmpty {
                    flushParagraph()
                    output.append(EPUBParser.imageMarker(for: href))
                }
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

    // MARK: - 图片标记

    /// 图片占位标记的前后缀。
    ///
    /// 形如 `\u{FFFC}IMG:../Images/pic.jpg\u{FFFC}`。
    /// 用 U+FFFC（OBJECT REPLACEMENT CHARACTER）而非方括号：
    /// 它在文本里几乎不可能自然出现，且宽度可预测，便于分页时定位。
    static let imageMarkerPrefix = "\u{FFFC}IMG:"
    static let imageMarkerSuffix = "\u{FFFC}"

    /// 构造图片标记。
    static func imageMarker(for source: String) -> String {
        "\(imageMarkerPrefix)\(source)\(imageMarkerSuffix)"
    }

    /// 从文本中解析出图片标记的位置与路径。
    ///
    /// - Parameter text: 章节纯文本。
    /// - Returns: 每处标记的字符区间与图片相对路径。
    static func imageReferences(in text: String) -> [(range: NSRange, source: String)] {
        let ns = text as NSString
        var results: [(range: NSRange, source: String)] = []
        var searchStart = 0

        while searchStart < ns.length {
            let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
            let prefixRange = ns.range(of: imageMarkerPrefix, options: [], range: searchRange)
            guard prefixRange.location != NSNotFound else { break }

            let pathStart = prefixRange.location + prefixRange.length
            let remaining = NSRange(location: pathStart, length: ns.length - pathStart)
            let suffixRange = ns.range(of: imageMarkerSuffix, options: [], range: remaining)
            guard suffixRange.location != NSNotFound else { break }

            let pathLength = suffixRange.location - pathStart
            guard pathLength > 0 else {
                searchStart = suffixRange.location + suffixRange.length
                continue
            }

            let source = ns.substring(with: NSRange(location: pathStart, length: pathLength))
            let fullRange = NSRange(
                location: prefixRange.location,
                length: suffixRange.location + suffixRange.length - prefixRange.location
            )
            results.append((range: fullRange, source: source))
            searchStart = fullRange.location + fullRange.length
        }

        return results
    }

    /// 把章节文本里的图片相对路径改写为解压目录内的绝对路径。
    ///
    /// - Parameters:
    ///   - text: 含 `[[IMG:相对路径]]` 标记的章节文本。
    ///   - chapterDirectory: 章节文件所在目录（相对解压根）。
    ///   - extractedRoot: 解压根目录的绝对路径。
    static func resolveImagePaths(
        in text: String,
        chapterDirectory: String,
        extractedRoot: URL
    ) -> String {
        let references = imageReferences(in: text)
        guard !references.isEmpty else { return text }

        let ns = text as NSString
        let mutable = NSMutableString(string: text)

        // 从后往前替换，避免 range 偏移
        for reference in references.reversed() {
            let source = reference.source
            // 跳过已经是绝对路径的（http:// 等外链不处理）
            guard !source.hasPrefix("http://"), !source.hasPrefix("https://") else {
                continue
            }

            let decoded = source.removingPercentEncoding ?? source
            let relative = chapterDirectory.isEmpty
                ? decoded
                : "\(chapterDirectory)/\(decoded)"
            let absolute = extractedRoot
                .appendingPathComponent(relative)
                .standardizedFileURL
                .path

            // 归一化 ../ 与 ./
            let normalized = (absolute as NSString).standardizingPath
            let replacement = imageMarker(for: normalized)
            mutable.replaceCharacters(in: reference.range, with: replacement)
        }

        _ = ns
        return mutable as String
    }

    /// 从章节文本中移除图片标记，只留正文。
    ///
    /// 用于分页：图片不参与文字排版，单独占位。
    static func strippingImageMarkers(_ text: String) -> String {
        var result = text
        while let start = result.range(of: imageMarkerPrefix),
              let end = result.range(of: imageMarkerSuffix, range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    private static func fallbackStripHTML(_ html: String) -> String {
        var text = html

        // 先把 <img src="..."> 换成图片标记，避免被下面的标签清理一并删掉
        if let imgRegex = try? NSRegularExpression(
            pattern: "<img[^>]*src\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>",
            options: [.caseInsensitive]
        ) {
            let ns = text as NSString
            let matches = imgRegex.matches(
                in: text,
                range: NSRange(location: 0, length: ns.length)
            )
            // 从后往前替换，避免 range 偏移
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let src = ns.substring(with: match.range(at: 1))
                text = (text as NSString).replacingCharacters(
                    in: match.range,
                    with: imageMarker(for: src)
                )
            }
        }

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
