//
//  ReadiumEPUBEngine.swift
//  ModuReader
//
//  EPUB 渲染引擎。基于 Readium 的 EPUBNavigatorViewController（WKWebView）。
//
//  ── 为什么 EPUB 交给 WebKit / Readium ──
//
//  EPUB 的排版能力来自 CSS：@font-face 内嵌字体、绝对定位、
//  图文绕排、竖排、SVG。自研的 TextKit 管线只能提取纯文本，
//  这些全部丢失 —— 表现为「特效字体渲染不出」「图片位置错乱」。
//
//  Readium 直接加载原始 XHTML + 出版方 CSS，保真度与桌面阅读器一致。
//  TXT / Markdown 仍走 TextKit 管线（文本格式没有 CSS，TextKit 更快更可控）。
//

import UIKit
import ReadiumShared
import ReadiumNavigator

@MainActor
final class ReadiumEPUBEngine: UIViewController, RenderEngine {

    // MARK: - RenderEngine

    let kind: EngineKind = .webKit

    var onLocatorChange: ((Locator) -> Void)?
    var onInteraction: ((ReaderInteraction) -> Void)?

    private(set) var chapters: [Chapter] = []
    private(set) var currentChapterIndex: Int = 0

    var currentLocator: Locator {
        convert(readiumLocator: navigator?.currentLocation)
    }

    var totalProgression: Double {
        navigator?.currentLocation?.locations.totalProgression
            ?? currentLocator.locations.totalProgression
            ?? 0
    }

    /// 承载视图（引擎自身）。
    var hostViewController: UIViewController { self }

    /// 全书总页数。WebKit 引擎没有页的概念，返回 0。
    var totalPageCountValue: Int { 0 }

    /// 当前页码。WebKit 引擎没有页的概念，返回 0。
    var currentPageNumber: Int { 0 }

    /// EPUB 自带字体由出版方 CSS 直接生效，无需开关。
    var hasBookFont: Bool { false }

    // MARK: - State

    private let fileStore: FileStore
    private var book: BookDescriptor?
    private var settings = ReaderSettings()
    private var publication: Publication?
    private var navigator: EPUBNavigatorViewController?
    private var chapterHrefs: [String] = []

    // MARK: - Init

    init(fileStore: FileStore) {
        self.fileStore = fileStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - Load

    func load(
        book: BookDescriptor,
        initialLocator: Locator?,
        settings: ReaderSettings
    ) async throws {
        self.book = book
        self.settings = settings

        // EPUB 原文件在导入时已复制为 Books/<id>/source.epub
        let epubURL = fileStore.bookDirectory(for: book.id)
            .appendingPathComponent("source.epub")

        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            throw ReadiumStackError.invalidURL
        }

        let publication = try await ReadiumStack.shared.openPublication(at: epubURL)
        self.publication = publication

        chapters = makeChapters(from: publication)
        chapterHrefs = publication.readingOrder.map { $0.anyURL.string }

        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialReadiumLocator(from: initialLocator),
            config: EPUBNavigatorViewController.Configuration(
                preferences: makePreferences(settings)
            )
        )
        navigator.delegate = self
        self.navigator = navigator

        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)

        syncChapterIndex()
        view.backgroundColor = settings.theme.uiBackgroundColor
    }

    // MARK: - Settings

    func apply(settings: ReaderSettings) async {
        self.settings = settings
        view.backgroundColor = settings.theme.uiBackgroundColor
        navigator?.submitPreferences(makePreferences(settings))
    }

    /// 把应用的阅读设置映射为 Readium 偏好。
    ///
    /// 单位换算说明（Readium 用相对单位，我们用 pt / 倍数）：
    /// - `fontSize` 是相对出版方默认字号的倍数（1.0 = 100%）
    /// - `lineHeight` 是行高倍数
    /// - `paragraphSpacing` / `paragraphIndent` / `letterSpacing` 单位是 em
    /// - `pageMargins` 是相对默认页边距的倍数
    /// - `publisherStyles = true` 保留出版方 CSS（内嵌字体、特效排版）
    private func makePreferences(_ settings: ReaderSettings) -> EPUBPreferences {
        let baseFontSize = 16.0

        let theme: Theme? = {
            switch settings.theme.name {
            case ReaderTheme.night.name, ReaderTheme.pureBlack.name: return .dark
            case ReaderTheme.sepia.name: return .sepia
            default: return .light
            }
        }()

        return EPUBPreferences(
            fontFamily: settings.useBookFont ? nil : settings.fontFamily.readiumFontFamily,
            fontSize: settings.useBookFont ? nil : Double(settings.fontSize) / baseFontSize,
            lineHeight: settings.lineHeightMultiple,
            pageMargins: Double(settings.horizontalPadding) / 24.0,
            paragraphIndent: Double(settings.firstLineIndent),
            paragraphSpacing: Double(settings.paragraphSpacing) / Double(max(1, settings.fontSize)),
            publisherStyles: settings.useBookFont,
            scroll: settings.readingMode == .scroll,
            theme: theme
        )
    }

    // MARK: - Navigation

    func nextPage() async -> Bool {
        guard let navigator else { return false }
        let moved = await navigator.goForward()
        if moved { syncChapterIndex(); onLocatorChange?(currentLocator) }
        return moved
    }

    func previousPage() async -> Bool {
        guard let navigator else { return false }
        let moved = await navigator.goBackward()
        if moved { syncChapterIndex(); onLocatorChange?(currentLocator) }
        return moved
    }

    func nextChapter() async {
        guard currentChapterIndex + 1 < chapters.count else { return }
        await goToChapter(at: currentChapterIndex + 1)
    }

    func previousChapter() async {
        guard currentChapterIndex > 0 else { return }
        await goToChapter(at: currentChapterIndex - 1)
    }

    func goToChapter(at index: Int) async {
        guard let publication, publication.readingOrder.indices.contains(index) else { return }
        let link = publication.readingOrder[index]
        _ = await navigator?.go(to: link)
        syncChapterIndex()
        onLocatorChange?(currentLocator)
    }

    func go(to locator: Locator, animated: Bool) async {
        guard let readium = initialReadiumLocator(from: locator) else { return }
        _ = await navigator?.go(to: readium)
        syncChapterIndex()
        onLocatorChange?(currentLocator)
    }

    func visibleText() -> String? { nil }

    func search(_ query: String) async -> [SearchResult] {
        // EPUB 搜索走 Readium 的 publication.search，需要异步序列处理，
        // 当前版本先不提供，返回空结果而不是假装搜到了什么。
        []
    }

    // MARK: - Chapter mapping

    /// 由 publication 生成章节列表。
    ///
    /// 标题优先取目录（tableOfContents）里对应 href 的 title，
    /// 没有则用 readingOrder 的 title，再没有就用「第 N 章」。
    private func makeChapters(from publication: Publication) -> [Chapter] {
        var titles: [String: String] = [:]
        collectTitles(from: publication.tableOfContents, into: &titles)

        var globalStart = 0
        return publication.readingOrder.enumerated().map { index, link in
            let href = link.anyURL.string
            let title = titles[href]
                ?? link.title
                ?? "第 \(index + 1) 章"
            // EPUB 由 WebKit 排版，这里不需要字符数；给 1 避免除零
            let chapter = Chapter(
                id: index,
                title: title,
                filePath: href,
                globalStart: globalStart,
                characterCount: 1
            )
            globalStart += 1
            return chapter
        }
    }

    private func collectTitles(from links: [Link], into map: inout [String: String]) {
        for link in links {
            if let title = link.title, !title.isEmpty {
                map[link.anyURL.string] = title
            }
            collectTitles(from: link.children, into: &map)
        }
    }

    /// 根据当前 locator 的 href 同步章节序号。
    private func syncChapterIndex() {
        guard let href = navigator?.currentLocation?.href.string,
              let index = chapterHrefs.firstIndex(of: href) else { return }
        currentChapterIndex = index
    }

    // MARK: - Locator conversion

    /// Readium Locator → 应用 Locator。
    ///
    /// 保存 href、资源内进度、全书进度与 Readium 的 position，
    /// 恢复时足以重建一个等价位置。
    private func convert(readiumLocator: ReadiumShared.Locator?) -> Locator {
        guard let readiumLocator else {
            return Locator(href: chapters.first?.filePath ?? "")
        }

        return Locator(
            href: readiumLocator.href.string,
            mediaType: "application/xhtml+xml",
            locations: Locations(
                progression: readiumLocator.locations.progression,
                totalProgression: readiumLocator.locations.totalProgression,
                charOffset: nil,
                page: readiumLocator.locations.position
            )
        )
    }

    /// 应用 Locator → Readium Locator。
    private func initialReadiumLocator(from locator: Locator?) -> ReadiumShared.Locator? {
        guard let locator, let publication else { return nil }

        // 按 href 找到 readingOrder 里对应的资源
        let link: Link? = {
            if !locator.href.isEmpty,
               let match = publication.readingOrder.first(where: {
                   $0.anyURL.string == locator.href
               }) {
                return match
            }
            return publication.readingOrder.first
        }()

        guard let link else { return nil }

        return ReadiumShared.Locator(
            href: link.anyURL,
            mediaType: link.mediaType ?? .xhtml,
            locations: .init(
                progression: locator.locations.progression,
                totalProgression: locator.locations.totalProgression,
                position: locator.locations.page
            )
        )
    }
}

// MARK: - EPUBNavigatorDelegate

extension ReadiumEPUBEngine: EPUBNavigatorDelegate {

    func navigator(_ navigator: Navigator, locationDidChange locator: ReadiumShared.Locator) {
        syncChapterIndex()
        onLocatorChange?(convert(readiumLocator: locator))
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        // 三分区点击：左侧上一页、右侧下一页、中间呼出工具栏
        let width = view.bounds.width
        guard width > 0 else { return }

        let ratio = point.x / width
        let zone = CGFloat(settings.tapZoneRatio)
        if ratio < zone {
            onInteraction?(.tapLeft)
        } else if ratio > 1 - zone {
            onInteraction?(.tapRight)
        } else {
            onInteraction?(.tapCenter)
        }
    }
}

// MARK: - 字体映射

private extension ReaderFontFamily {
    /// 映射到 Readium 可识别的字体族名。
    ///
    /// Readium 的 `FontFamily` 是字符串包装，直接传 PostScript 名或族名。
    var readiumFontFamily: FontFamily? {
        switch self {
        case .system: return nil
        case .serif: return "Georgia"
        case .songti: return "Songti SC"
        case .kaiti: return "Kaiti SC"
        case .fangsong: return "STFangsong"
        case .pingfang: return "PingFang SC"
        }
    }
}