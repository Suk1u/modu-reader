//
//  ReadiumEPUBEngine.swift
//  ModuReader
//
//  EPUB 渲染引擎。基于 Readium 的 EPUBNavigatorViewController（WKWebView）。
//
//  ── 两个渲染源 ──
//
//  滚动模式：加载**全书合并版**。Readium 的滚动是按资源的，不合并的话
//  滚到章末会停住；合并后整本是一条连续内容流，才能无缝上下滑。
//
//  翻页模式：加载**原书**。合并版是单个超大资源，分页要靠 WebKit
//  对整本书做多栏布局，代价高且容易出问题（实测表现为整页空白）。
//  翻页模式本来就是按资源分页的，原书每个章节一个资源，正是 Readium
//  最成熟的路径，页数也按章计算。
//
//  两者在切换阅读方式时互换，位置用全书进度对齐。
//

import SwiftUI
import UIKit
import WebKit
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumNavigator

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

    /// 滚动中的实时进度。
    ///
    /// 合并版只有一个资源，WebView 的滚动比例就是全书进度。
    /// Readium 的位置回调只在停稳时触发，靠它推不动进度条。
    var liveProgression: Double {
        guard source == .merged,
              let webView = Self.visibleWebView(in: view) else {
            return totalProgression
        }

        let scroll = webView.scrollView
        let insetTop = scroll.adjustedContentInset.top
        let insetBottom = scroll.adjustedContentInset.bottom
        let scrollable = scroll.contentSize.height + insetTop + insetBottom - scroll.bounds.height
        guard scrollable > 1 else { return totalProgression }

        let ratio = (scroll.contentOffset.y + insetTop) / scrollable
        return min(max(ratio, 0), 1)
    }

    /// 全书总页数。
    var totalPageCountValue: Int { totalPositions }

    /// 当前页码（1 起）。
    var currentPageNumber: Int {
        navigator?.currentLocation?.locations.position ?? 0
    }

    /// EPUB 自带字体由出版方 CSS 直接生效，无需开关。
    var hasBookFont: Bool { false }

    // MARK: - 渲染源

    /// 阅读内容的来源。
    private enum Source: Hashable {
        /// 原始 EPUB（翻页模式）。
        case original
        /// 全书合并版（滚动模式）。
        case merged
    }

    // MARK: - State

    private let fileStore: FileStore
    private var book: BookDescriptor?
    private var settings = ReaderSettings()

    private var epubURL: URL?
    private var mergedURL: URL?

    private var publication: ReadiumShared.Publication?
    private var navigator: EPUBNavigatorViewController?
    private var source: Source = .original

    private var chapterHrefs: [String] = []
    private var totalPositions = 0
    /// 全书位置列表，用于按总进度精确定位。
    private var positions: [ReadiumShared.Locator] = []
    /// 按来源缓存，避免来回切换阅读方式时重复计算。
    private var positionsCache: [Source: [ReadiumShared.Locator]] = [:]
    /// 合并版的目录链接（每个条目带锚点）。
    private var tocLinks: [ReadiumShared.Link] = []
    /// 每章起始的全书进度，用于按进度反查章节。
    private var chapterStarts: [Double] = []
    /// 待渲染的高亮。
    private var highlightMarks: [HighlightMark] = []
    /// 章节定位是否按全书进度走（合并版只有单个资源，只能这样）。
    private var syncByProgression = false
    /// 位置统计的代数号。切换来源或重新打开时递增，
    /// 用来丢弃过期的后台统计结果。
    private var positionsGeneration = 0
    /// 是否正在切换渲染源。
    private var isSwitchingSource = false

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

        let bookDirectory = fileStore.bookDirectory(for: book.id)
        let originalURL: URL
        switch book.kind {
        case .epubReflowable, .epubFixedLayout:
            originalURL = bookDirectory.appendingPathComponent("source.epub")
        default:
            originalURL = try TextEPUBBuilder.buildIfNeeded(fileStore: fileStore, book: book)
        }

        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw ReadiumStackError.invalidURL
        }

        epubURL = originalURL

        // 产物名带算法版本号：旧的合并文档缺少命名空间声明，
        // 会让 WebKit 报「Namespace prefix epub for type」并只渲染到出错行。
        mergedURL = bookDirectory.appendingPathComponent("merged-v\(EPUBMerger.version).epub")

        // 清掉历史版本的合并产物（v1 缺少命名空间声明、v2 目录是扁平的），
        // 它们只会白占空间。
        if let names = try? FileManager.default.contentsOfDirectory(atPath: bookDirectory.path) {
            let current = mergedURL?.lastPathComponent
            for name in names
            where name.hasPrefix("merged") && name.hasSuffix(".epub") && name != current {
                try? FileManager.default.removeItem(at: bookDirectory.appendingPathComponent(name))
            }
        }

        let desired: Source = preferredSource(for: settings)
        let actual = await resolveSource(desired)

        try await open(source: actual, initialLocator: initialLocator)

        syncChapterIndex()

        view.backgroundColor = settings.theme.uiBackgroundColor
        scheduleOverflowProbe()
        Diagnostics.log(
            "ReadiumEPUB: \(actual == .merged ? "合并版" : "原书")，共 \(totalPositions) 个位置，\(chapters.count) 章"
        )
    }

    /// 当前设置下应当使用的渲染源。
    private func preferredSource(for settings: ReaderSettings) -> Source {
        // 固定版式不能合并
        guard book?.kind != .epubFixedLayout else { return .original }
        return settings.readingMode == .scroll ? .merged : .original
    }

    /// 尝试得到目标来源；合并不可用时退回原书。
    private func resolveSource(_ desired: Source) async -> Source {
        guard desired == .merged else { return .original }
        do {
            _ = try await url(for: .merged)
            return .merged
        } catch {
            return .original
        }
    }

    /// 取得某个来源对应的文件，必要时现场生成合并版。
    private func url(for source: Source) async throws -> URL {
        switch source {
        case .original:
            guard let epubURL else { throw ReadiumStackError.invalidURL }
            return epubURL

        case .merged:
            guard let epubURL, let mergedURL else { throw ReadiumStackError.invalidURL }
            if FileManager.default.fileExists(atPath: mergedURL.path) {
                return mergedURL
            }
            do {
                let summary = try EPUBMerger.buildMerged(from: epubURL, to: mergedURL)
                Diagnostics.log("ReadiumEPUB: 已生成合并版（\(summary.chapterCount) 章 / \(summary.tocCount) 目录项）")
                return mergedURL
            } catch EPUBMergeError.notNeeded {
                Diagnostics.log("ReadiumEPUB: 单资源，无需合并")
                throw EPUBMergeError.notNeeded
            } catch {
                // 半成品必须删掉，否则下次启动会被当成有效产物直接加载。
                try? FileManager.default.removeItem(at: mergedURL)
                Diagnostics.log("ReadiumEPUB: 合并失败，使用原文件 — \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// 打开指定来源并挂载导航器。
    private func open(source newSource: Source, initialLocator: Locator?) async throws {
        let fileURL = try await url(for: newSource)
        let publication = try await ReadiumStack.shared.openPublication(at: fileURL)

        self.publication = publication
        self.source = newSource

        chapters = await makeChapters(from: publication)

        // 恢复位置可能需要位置列表（旧的 href 属于另一个来源）。
        positionsGeneration += 1
        let generation = positionsGeneration

        // 其余情况把位置统计放到导航器之后，避免拖慢首屏。
        let needsPositions = needsPositionsToRestore(initialLocator, in: publication)
        positions = needsPositions
            ? await loadPositions(from: publication, source: newSource)
            : []
        totalPositions = positions.count

        let initial = readiumLocator(from: initialLocator)
        let navigator = try makeNavigator(publication: publication, initialLocation: initial)
        self.navigator = navigator
        attachNavigator(navigator)
        renderHighlights()

        if !needsPositions {
            let publication = publication
            let source = newSource
            Task { [weak self] in
                guard let self else { return }
                let list = await self.loadPositions(from: publication, source: source)
                guard self.positionsGeneration == generation else { return }
                self.positions = list
                self.totalPositions = list.count
                // 原书的章节页码依赖位置列表，拿到之后重算一次
                await self.rebuildChapterStarts()
                self.syncChapterIndex()
            }
        }

        syncChapterIndex()
    }

    /// 恢复位置是否需要位置列表。
    ///
    /// 保存的 href 属于另一个渲染源时（例如上次在滚动模式读合并版，
    /// 这次在翻页模式读原书），只能靠全书进度定位。
    private func needsPositionsToRestore(
        _ locator: Locator?,
        in publication: ReadiumShared.Publication
    ) -> Bool {
        guard let locator else { return false }
        guard let target = locator.locations.totalProgression, target > 0 else { return false }
        if locator.href.isEmpty { return true }
        return !publication.readingOrder.contains { $0.anyURL.string == locator.href }
    }

    // MARK: - Settings

    func apply(settings: ReaderSettings) async {
        let previousMode = self.settings.readingMode
        self.settings = settings
        view.backgroundColor = settings.theme.uiBackgroundColor

        // 阅读方式在「滚动 / 翻页」之间变化时，渲染源要跟着换。
        if (previousMode == .scroll) != (settings.readingMode == .scroll) {
            await switchSourceIfNeeded()
            return
        }

        navigator?.submitPreferences(makePreferences(settings))
    }

    /// 按当前阅读方式切换渲染源。
    private func switchSourceIfNeeded() async {
        let desired = preferredSource(for: settings)
        guard desired != source else {
            navigator?.submitPreferences(makePreferences(settings))
            return
        }

        // 连续切换阅读方式时只跑最后一次，避免两个切换交错。
        guard !isSwitchingSource else { return }
        isSwitchingSource = true
        defer { isSwitchingSource = false }

        let progression = navigator?.currentLocation?.locations.totalProgression
            ?? totalProgression

        do {
            let fileURL = try await url(for: desired)
            let newPublication = try await ReadiumStack.shared.openPublication(at: fileURL)
            let newPositions = await loadPositions(from: newPublication, source: desired)

            detachNavigator()

            positionsGeneration += 1
            publication = newPublication
            source = desired
            positions = newPositions
            totalPositions = newPositions.count
            chapters = await makeChapters(from: newPublication)

            let initial = closestPosition(to: progression)
            let navigator = try makeNavigator(publication: newPublication, initialLocation: initial)
            self.navigator = navigator
            attachNavigator(navigator)
            renderHighlights()

            syncChapterIndex()
            onLocatorChange?(currentLocator)
            Diagnostics.log(
                "ReadiumEPUB: 切换渲染源 → \(desired == .merged ? "合并版" : "原书")，进度 \(Int(progression * 100))%"
            )
            scheduleOverflowProbe()
        } catch {
            // 切换失败就留在当前来源，只应用排版偏好。
            Diagnostics.log("ReadiumEPUB: 切换渲染源失败 — \(error.localizedDescription)")
            navigator?.submitPreferences(makePreferences(settings))
        }
    }

    // MARK: - 诊断

    /// 滚动模式下探测「有没有元素宽于视口」。
    ///
    /// 溢出的成因取决于每本书的出版方 CSS，光看代码推不出来，
    /// 所以直接在 WebView 里量一遍，把最宽的几个元素写进日志。
    private func scheduleOverflowProbe() {
        guard settings.readingMode == .scroll else { return }

        Task { [weak self] in
            try? await Task<Never, Never>.sleep(for: .seconds(2))
            guard let self, self.settings.readingMode == .scroll else { return }
            guard let webView = Self.firstWebView(in: self.view) else {
                Diagnostics.log("ReadiumEPUB: 宽度探针未找到 WebView")
                return
            }

            let script = """
            (function(){
              var vw = window.innerWidth;
              var sw = document.documentElement.scrollWidth;
              var bw = document.body ? document.body.scrollWidth : -1;
              var list = [];
              var nodes = document.body ? document.body.querySelectorAll('*') : [];
              for (var i = 0; i < nodes.length && list.length < 6; i++) {
                var el = nodes[i];
                var r = el.getBoundingClientRect();
                if (r.width > vw + 1 || r.right > vw + 1 || r.left < -1) {
                  var cls = (typeof el.className === 'string') ? el.className.split(' ')[0] : '';
                  list.push(el.tagName + (el.id ? '#' + el.id : '') + (cls ? '.' + cls : '') +
                    '[w=' + Math.round(r.width) + ',l=' + Math.round(r.left) + ',r=' + Math.round(r.right) + ']');
                }
              }
              return 'vw=' + vw + ' html.sw=' + sw + ' body.sw=' + bw + ' | ' + list.join(' ; ');
            })();
            """

            do {
                let value = try await webView.evaluateJavaScript(script)
                Diagnostics.log("ReadiumEPUB: 宽度探针 \(value as? String ?? "无结果")")
            } catch {
                Diagnostics.log("ReadiumEPUB: 宽度探针失败 \(error.localizedDescription)")
            }
        }
    }

    /// 取当前真正可见的那个 WebView（预加载的兄弟视图不算）。
    private static func visibleWebView(in root: UIView) -> WKWebView? {
        var best: WKWebView?
        var bestArea: CGFloat = 0

        func walk(_ view: UIView) {
            if let webView = view as? WKWebView, webView.bounds.width > 1 {
                let frame = webView.convert(webView.bounds, to: root)
                let intersection = frame.intersection(root.bounds)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    best = webView
                }
            }
            for subview in view.subviews {
                walk(subview)
            }
        }

        walk(root)
        return best
    }

    private static func firstWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView, webView.bounds.width > 1 {
            return webView
        }
        for subview in view.subviews {
            if let found = firstWebView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func makeNavigator(
        publication: ReadiumShared.Publication,
        initialLocation: ReadiumShared.Locator?
    ) throws -> EPUBNavigatorViewController {
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocation,
            config: EPUBNavigatorViewController.Configuration(
                preferences: makePreferences(settings),
                // 选中文字后弹出「高亮标记」
                editingActions: EditingAction.defaultActions + [
                    EditingAction(
                        title: "高亮标记",
                        action: #selector(highlightSelectionAction)
                    ),
                ],
                // 滚动模式下禁用翻页手势。
                // 纵向滚动时手指常带横向位移，会误触发翻页，产生跳页感。
                // 该开关只在 scroll 生效（源码里是 `disable && settings.scroll`），
                // 因此可以无条件设为 true，不影响分页模式的翻页。
                disablePageTurnsWhileScrolling: true,
                // 取消 Readium 默认的上下内容内边距（compact 34pt / regular 62pt）。
                contentInset: [
                    .compact: (top: 0, bottom: 0),
                    .regular: (top: 0, bottom: 0),
                ]
            )
        )
        navigator.delegate = self
        return navigator
    }

    private func attachNavigator(_ navigator: EPUBNavigatorViewController) {
        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [
            UIView.AutoresizingMask.flexibleWidth,
            UIView.AutoresizingMask.flexibleHeight,
        ]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)
    }

    private func detachNavigator() {
        guard let navigator else { return }
        navigator.willMove(toParent: nil)
        navigator.view.removeFromSuperview()
        navigator.removeFromParent()
        navigator.delegate = nil
        self.navigator = nil
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
            backgroundColor: ReadiumNavigator.Color(hex: settings.theme.background.hexString),
            fontFamily: settings.useBookFont ? nil : settings.fontFamily.readiumFontFamily,
            fontSize: settings.useBookFont ? nil : Double(settings.fontSize) / baseFontSize,
            lineHeight: settings.lineHeightMultiple,
            pageMargins: Double(settings.horizontalPadding) / 24.0,
            paragraphIndent: Double(settings.firstLineIndent),
            paragraphSpacing: Double(settings.paragraphSpacing) / Double(max(1, settings.fontSize)),
            publisherStyles: settings.useBookFont,
            scroll: settings.readingMode == .scroll,
            textColor: ReadiumNavigator.Color(hex: settings.theme.text.hexString),
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
        guard let target = navigableIndex(from: currentChapterIndex, step: 1) else { return }
        await goToChapter(at: target)
    }

    func previousChapter() async {
        guard let target = navigableIndex(from: currentChapterIndex, step: -1) else { return }
        await goToChapter(at: target)
    }

    /// 下一个可跳转的章节序号。
    ///
    /// 目录里的分组节点（有子项、自身不占独立正文）不参与前后翻章，
    /// 否则「下一章」会停在原地。
    private func navigableIndex(from index: Int, step: Int) -> Int? {
        var candidate = index + step
        while chapters.indices.contains(candidate) {
            if !chapters[candidate].isGroup {
                return candidate
            }
            candidate += step
        }
        return nil
    }

    func goToChapter(at index: Int) async {
        guard chapters.indices.contains(index) else { return }

        // 合并版：章节是目录条目（带锚点）
        if tocLinks.indices.contains(index) {
            _ = await navigator?.go(to: tocLinks[index])
        } else if let publication, publication.readingOrder.indices.contains(index) {
            _ = await navigator?.go(to: publication.readingOrder[index])
        }

        syncChapterIndex()
        onLocatorChange?(currentLocator)
    }

    func go(to locator: Locator, animated: Bool) async {
        // 目录条目（合并版的锚点）优先按 Link 跳转
        if !locator.href.isEmpty,
           let link = tocLinks.first(where: { $0.href == locator.href }) {
            _ = await navigator?.go(to: link)
            syncChapterIndex()
            onLocatorChange?(currentLocator)
            return
        }

        // 只有总进度（进度条拖动）时，需要位置列表才能定位
        if locator.href.isEmpty,
           let target = locator.locations.totalProgression,
           positions.isEmpty,
           let publication {
            positions = await loadPositions(from: publication, source: source)
            totalPositions = positions.count
        }

        guard let readium = readiumLocator(from: locator) else { return }
        _ = await navigator?.go(to: readium)
        syncChapterIndex()
        onLocatorChange?(currentLocator)
    }

    func visibleText() -> String? { nil }

    func search(_ query: String) async -> [SearchResult] {
        guard let publication else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        switch await publication.search(query: trimmed) {
        case .failure(let error):
            Diagnostics.log("ReadiumEPUB: 搜索不可用 — \(error)")
            return []

        case .success(let iterator):
            var results: [SearchResult] = []
            // 上限保护：整本命中几千条时，列表也会卡
            while !Task.isCancelled, results.count < 200 {
                switch await iterator.next() {
                case .failure:
                    return results
                case .success(let collection):
                    guard let collection else { return results }
                    for locator in collection.locators {
                        results.append(makeSearchResult(from: locator, fallback: trimmed))
                    }
                }
            }
            Diagnostics.log("ReadiumEPUB: 搜索「\(trimmed)」命中 \(results.count) 条")
            return results
        }
    }

    private func makeSearchResult(
        from locator: ReadiumShared.Locator,
        fallback: String
    ) -> SearchResult {
        let index = chapterIndex(for: locator)
        let title = chapters.indices.contains(index) ? chapters[index].title : ""
        let highlight = locator.text.highlight?.isEmpty == false
            ? locator.text.highlight!
            : fallback

        return SearchResult(
            chapterIndex: index,
            chapterTitle: title,
            charOffset: 0,
            context: (locator.text.before ?? "") + highlight + (locator.text.after ?? ""),
            matchedText: highlight,
            href: locator.href.string,
            progression: locator.locations.progression
        )
    }

    /// 搜索结果落在哪一章。
    private func chapterIndex(for locator: ReadiumShared.Locator) -> Int {
        if !chapterStarts.isEmpty, let total = locator.locations.totalProgression {
            var index = 0
            for (i, start) in chapterStarts.enumerated() where start <= total + 1e-9 {
                index = i
            }
            return index
        }
        let key = normalizedHref(locator.href.string)
        return chapterHrefs.firstIndex(of: key) ?? 0
    }

    // MARK: - Positions

    private func loadPositions(
        from publication: ReadiumShared.Publication,
        source: Source
    ) async -> [ReadiumShared.Locator] {
        if let cached = positionsCache[source] {
            return cached
        }
        if case .success(let list) = await publication.positions() {
            positionsCache[source] = list
            return list
        }
        return []
    }

    /// 重新计算每章的起始进度（需要位置列表已就绪）。
    private func rebuildChapterStarts() async {
        guard let publication, !tocLinks.isEmpty else { return }

        var starts: [Double] = []
        starts.reserveCapacity(tocLinks.count)
        for link in tocLinks {
            let located = await publication.locate(link)
            let raw = located?.locations.totalProgression
                ?? (Double(starts.count) / Double(max(1, tocLinks.count)))
            starts.append(max(raw, starts.last ?? 0))
        }
        chapterStarts = starts
    }

    /// 按全书进度找最接近的位置。
    private func closestPosition(to progression: Double) -> ReadiumShared.Locator? {
        guard !positions.isEmpty else { return nil }
        let target = max(0, min(1, progression))
        let index = Int((target * Double(positions.count - 1)).rounded())
        return positions[max(0, min(positions.count - 1, index))]
    }

    // MARK: - Chapter mapping

    /// 由 publication 生成章节列表。
    ///
    /// **优先用目录**，而不是 readingOrder：
    /// - 目录的标题是原书给的，spine 链接往往没有 title，只能退化成「第 N 章」
    /// - 目录的顺序才是阅读顺序，spine 里常混着封面 / 书名页 / 版权页
    /// - 目录的层级（卷 → 章）要保留给目录面板
    private func makeChapters(from publication: ReadiumShared.Publication) async -> [Chapter] {
        var entries: [(link: ReadiumShared.Link, level: Int, isGroup: Bool)] = []
        if case .success(let links) = await publication.tableOfContents() {
            entries = flattenTOC(links, level: 0)
        }

        if entries.count > 1 {
            var result: [Chapter] = []
            var links: [ReadiumShared.Link] = []
            var hrefs: [String] = []
            var starts: [Double] = []

            // 合并版只有一个资源，只能靠全书进度区分章节；
            // 原书仍按 href 判断当前章，但起始进度两处都要用（页码换算）。
            let useProgression = publication.readingOrder.count == 1
            syncByProgression = useProgression

            for (index, entry) in entries.enumerated() {
                let title = entry.link.title.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "第 \(index + 1) 章"

                result.append(
                    Chapter(
                        id: index,
                        title: title,
                        filePath: entry.link.href,
                        globalStart: index,
                        characterCount: 1,
                        level: entry.level,
                        isGroup: entry.isGroup
                    )
                )
                links.append(entry.link)
                hrefs.append(normalizedHref(entry.link.href))

                let located = await publication.locate(entry.link)
                let raw = located?.locations.totalProgression
                    ?? (Double(index) / Double(max(1, entries.count)))
                // 位置必须单调不减，否则按进度反查章节会错位
                starts.append(max(raw, starts.last ?? 0))
            }

            chapterStarts = starts
            tocLinks = links
            chapterHrefs = hrefs
            return result
        }

        // 目录不可用：退回按 readingOrder 排列。
        chapterStarts = []
        tocLinks = []
        syncByProgression = false
        chapterHrefs = publication.readingOrder.map { normalizedHref($0.anyURL.string) }

        var globalStart = 0
        return publication.readingOrder.enumerated().map { index, link in
            let chapter = Chapter(
                id: index,
                title: link.title ?? "第 \(index + 1) 章",
                filePath: link.anyURL.string,
                globalStart: globalStart,
                characterCount: 1
            )
            globalStart += 1
            return chapter
        }
    }

    /// 归一化 href：去掉片段、解码百分号、去掉 `./` 与开头的 `/`。
    ///
    /// 目录里的 `ch1.xhtml#sec2` 与 readingOrder / 当前定位里的
    /// `ch1.xhtml` 必须能对上，否则标题会全部掉进「第 N 章」。
    private func normalizedHref(_ raw: String) -> String {
        var value = raw
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        value = value.removingPercentEncoding ?? value
        while value.hasPrefix("./") {
            value.removeFirst(2)
        }
        while value.hasPrefix("/") {
            value.removeFirst()
        }
        return value
    }

    /// 深度优先展平目录树，保留层级并为有子项的节点打上分组标记。
    private func flattenTOC(
        _ links: [ReadiumShared.Link],
        level: Int
    ) -> [(link: ReadiumShared.Link, level: Int, isGroup: Bool)] {
        var result: [(link: ReadiumShared.Link, level: Int, isGroup: Bool)] = []
        for link in links {
            result.append((link: link, level: level, isGroup: !link.children.isEmpty))
            if !link.children.isEmpty {
                result.append(contentsOf: flattenTOC(link.children, level: level + 1))
            }
        }
        return result
    }

    /// 同步当前章节序号。
    ///
    /// 合并版的所有章节共用一个 href，无法按 href 区分，
    /// 因此改用「章节起始进度」做二分查找。
    private func syncChapterIndex() {
        if syncByProgression, !chapterStarts.isEmpty {
            let progression = navigator?.currentLocation?
                .locations.totalProgression ?? 0
            var index = 0
            for (i, start) in chapterStarts.enumerated() where start <= progression + 1e-9 {
                index = i
            }
            // 分组节点与其首个子项起点相同，取更深的那一层
            while index + 1 < chapterStarts.count,
                  abs(chapterStarts[index + 1] - chapterStarts[index]) < 1e-9,
                  chapters.indices.contains(index + 1) {
                index += 1
            }
            currentChapterIndex = index
            return
        }

        guard let href = navigator?.currentLocation?.href.string else { return }
        let key = normalizedHref(href)
        if let index = chapterHrefs.firstIndex(of: key) {
            currentChapterIndex = index
        }
    }

    // MARK: - 高亮标记

    private static let highlightGroup = "modu.highlight"

    /// 选择菜单里的「高亮标记」。
    @objc private func highlightSelectionAction() {
        guard let selection = navigator?.currentSelection else { return }
        navigator?.clearSelection()
        onInteraction?(.highlight(convert(readiumLocator: selection.locator), selection.frame))
    }

    func applyHighlights(_ marks: [HighlightMark]) {
        highlightMarks = marks
        renderHighlights()
    }

    private func renderHighlights() {
        guard let navigator, let publication else { return }

        let defaultTint = settings.highlightRGB
        let defaultUnderline = settings.usesUnderlineHighlight
        var decorations: [Decoration] = []
        decorations.reserveCapacity(highlightMarks.count)

        for mark in highlightMarks {
            // 只画当前渲染源里的书（合并版与原书的 href 不同）
            guard publication.readingOrder.contains(where: {
                $0.anyURL.string == mark.locator.href
            }) else { continue }

            guard let readium = decoratorLocator(for: mark.locator) else { continue }

            let rgb = mark.tintHex.flatMap { RGBColor(hex: $0) } ?? defaultTint
            let tint = UIColor(rgb.color)
            let style: Decoration.Style = (mark.underline || defaultUnderline)
                ? .underline(tint: tint)
                : .highlight(tint: tint)

            decorations.append(
                Decoration(
                    id: mark.id.uuidString,
                    locator: readium,
                    style: style
                )
            )
        }

        navigator.apply(decorations: decorations, in: Self.highlightGroup)
    }

    private func decoratorLocator(for locator: Locator) -> ReadiumShared.Locator? {
        guard let publication,
              let link = publication.readingOrder.first(where: {
                  $0.anyURL.string == locator.href
              }) else {
            return nil
        }

        let quote = locator.text

        return ReadiumShared.Locator(
            href: link.anyURL,
            mediaType: link.mediaType ?? .xhtml,
            locations: .init(
                progression: locator.locations.progression,
                totalProgression: locator.locations.totalProgression,
                position: locator.locations.page
            ),
            text: ReadiumShared.Locator.Text(
                after: quote?.after,
                before: quote?.before,
                highlight: quote?.highlight
            )
        )
    }

    /// 把指定落点滚到屏幕中央。
    ///
    /// 合并版是单个资源，用「内容高度 × 进度」直接算出目标偏移，
    /// 比自己相对 Readium 的落点再挪半屏可靠。
    func centerCurrentPosition(at locator: Locator) {
        guard source == .merged else { return }

        Task { [weak self] in
            try? await Task<Never, Never>.sleep(for: .milliseconds(320))
            guard let self, let webView = Self.visibleWebView(in: self.view) else { return }

            let scroll = webView.scrollView
            let progress = locator.locations.totalProgression
                ?? locator.locations.progression
                ?? 0
            let insetTop = scroll.adjustedContentInset.top
            let target = scroll.contentSize.height * min(max(progress, 0), 1)
                - scroll.bounds.height / 2
            let lower = -insetTop
            let upper = max(
                lower,
                scroll.contentSize.height + scroll.adjustedContentInset.bottom
                    - scroll.bounds.height
            )

            scroll.setContentOffset(
                CGPoint(
                    x: scroll.contentOffset.x,
                    y: min(max(target, lower), upper)
                ),
                animated: true
            )
        }
    }

    // MARK: - 章节页码

    /// 当前章节的页码范围。
    ///
    /// 合并版把章节的起始进度按全书位置数换算成页码；
    /// 原书（翻页模式）没有章节起始进度，返回 nil，界面退化为全书页码。
    func chapterPageRange() -> ClosedRange<Int>? {
        guard !chapterStarts.isEmpty,
              totalPositions > 0,
              chapters.indices.contains(currentChapterIndex) else { return nil }

        let start = Int((chapterStarts[currentChapterIndex] * Double(totalPositions)).rounded(.down)) + 1
        let nextStart: Int
        if currentChapterIndex + 1 < chapterStarts.count {
            nextStart = Int((chapterStarts[currentChapterIndex + 1] * Double(totalPositions)).rounded(.down)) + 1
        } else {
            nextStart = totalPositions + 1
        }

        let lower = min(max(start, 1), totalPositions)
        let upper = min(max(nextStart - 1, lower), totalPositions)
        return lower...upper
    }

    func pageNumber(forChapter index: Int) -> Int? {
        guard !chapterStarts.isEmpty,
              totalPositions > 0,
              chapterStarts.indices.contains(index) else { return nil }
        let page = Int((chapterStarts[index] * Double(totalPositions)).rounded(.down)) + 1
        return min(max(page, 1), totalPositions)
    }

    func chapterIndex(atProgression progression: Double) -> Int? {
        guard !chapterStarts.isEmpty else { return nil }
        var index = 0
        for (i, start) in chapterStarts.enumerated() where start <= progression + 1e-9 {
            index = i
        }
        // 分组节点与其首个子项起点相同，取更深的那一层
        while index + 1 < chapterStarts.count,
              abs(chapterStarts[index + 1] - chapterStarts[index]) < 1e-9 {
            index += 1
        }
        return chapters.indices.contains(index) ? index : nil
    }

    func chapterTitle(atProgression progression: Double) -> String? {
        guard let index = chapterIndex(atProgression: progression) else { return nil }
        return chapters[index].title
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
            ),
            // 文本引用是高亮能重新锚定的关键，必须一起存。
            // 注意 Readium 的 text 是非可选结构体，空引用时 highlight 为 nil。
            text: readiumLocator.text.highlight.map { highlight in
                TextQuote(
                    before: readiumLocator.text.before,
                    highlight: highlight,
                    after: readiumLocator.text.after
                )
            }
        )
    }

    /// 应用 Locator → Readium Locator。
    ///
    /// 只有总进度（例如进度条拖动、跨来源切换）时，用 positions 找最接近的位置。
    /// 直接把 href 设为第一章会让 WebKit 跳到章首，而不是目标进度。
    private func readiumLocator(from locator: Locator?) -> ReadiumShared.Locator? {
        guard let locator, let publication else { return nil }

        let hasMatchingResource = !locator.href.isEmpty
            && publication.readingOrder.contains { $0.anyURL.string == locator.href }

        if !hasMatchingResource,
           let target = locator.locations.totalProgression,
           let position = closestPosition(to: target) {
            return position
        }

        let link: ReadiumShared.Link? = {
            if hasMatchingResource,
               let match = publication.readingOrder.first(where: {
                   $0.anyURL.string == locator.href
               }) {
                return match
            }
            return publication.readingOrder.first
        }()

        guard let link else { return nil }

        // 带上文本引用，Readium 才能锚到确切的那一段，
        // 而不是只按进度落到附近的页边界。
        let quote = locator.text

        return ReadiumShared.Locator(
            href: link.anyURL,
            mediaType: link.mediaType ?? .xhtml,
            locations: .init(
                progression: locator.locations.progression,
                totalProgression: locator.locations.totalProgression,
                position: locator.locations.page
            ),
            text: ReadiumShared.Locator.Text(
                after: quote?.after,
                before: quote?.before,
                highlight: quote?.highlight
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

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        Diagnostics.log("ReadiumEPUB: navigator error \(error.localizedDescription)")
    }

    /// 脚注锚点前缀。合并器把 `<a epub:type="noteref">` 的 href
    /// 改写成 `#modu-note-<id>`，这里据此在跳转前拦截。
    private static let noteAnchorPrefix = "modu-note-"

    func navigator(
        _ navigator: EPUBNavigatorViewController,
        shouldNavigateToLink link: ReadiumShared.Link
    ) -> Bool {
        guard let anchor = Self.noteAnchorID(in: link.href) else { return true }

        // 无论哪种显示方式都不跳转；气泡模式再去取内容
        if settings.noteDisplayMode == .popover {
            presentNote(forAnchor: anchor)
        }
        return false
    }

    private static func noteAnchorID(in href: String) -> String? {
        guard let range = href.range(of: "#" + noteAnchorPrefix) else { return nil }
        return String(href[range.upperBound...])
    }

    private func presentNote(forAnchor anchor: String) {
        Task { [weak self] in
            guard let self, let webView = Self.visibleWebView(in: self.view) else { return }

            let literal = (try? JSONEncoder().encode(anchor))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let script = """
            (function(){
              var el = document.getElementById(\(literal));
              if (!el) { return ""; }
              var r = el.getBoundingClientRect();
              return JSON.stringify({
                text: (el.innerText || el.textContent || '').trim(),
                x: r.left + r.width / 2,
                y: r.top + r.height / 2
              });
            })()
            """

            guard let value = try? await webView.evaluateJavaScript(script),
                  let raw = value as? String,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            let text = (object["text"] as? String) ?? ""
            guard !text.isEmpty else { return }

            self.presentNote(
                content: text,
                referrer: "",
                anchor: CGPoint(
                    x: (object["x"] as? Double) ?? Double(self.view.bounds.midX),
                    y: (object["y"] as? Double) ?? Double(self.view.bounds.midY)
                ),
                in: webView
            )
        }
    }

    /// 脚注点击。永远不跳转 —— 注释正文就在段落下方，
    /// 跳过去反而打断阅读。
    func navigator(
        _ navigator: EPUBNavigatorViewController,
        shouldNavigateToNoteAt link: ReadiumShared.Link,
        content: String,
        referrer: String
    ) -> Bool {
        // Readium 自己认出了脚注时走这条路径 —— 气泡必须在这里也弹一次，
        // 否则只会「吞掉点击」而什么也不发生。
        if settings.noteDisplayMode == .popover,
           let anchor = Self.noteAnchorID(in: link.href) {
            presentNote(forAnchor: anchor)
        }
        return false
    }

    private func presentNote(
        content: String,
        referrer: String,
        anchor: CGPoint,
        in webView: WKWebView?
    ) {
        guard presentedViewController == nil, !content.isEmpty else { return }

        let host = UIHostingController(
            rootView: NoteBubbleView(referrer: referrer, content: content)
        )
        host.modalPresentationStyle = .popover
        host.view.backgroundColor = .clear

        var sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.midY,
            width: 1,
            height: 1
        )
        if let webView {
            let point = webView.convert(anchor, to: view)
            sourceRect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        }

        if let popover = host.popoverPresentationController {
            popover.delegate = self
            popover.sourceView = view
            popover.sourceRect = sourceRect
            popover.permittedArrowDirections = [.up, .down]
            popover.backgroundColor = .clear
        }

        present(host, animated: true)
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        // 三分区点击：左侧上一页、右侧下一页、中间呼出工具栏
        let width = view.bounds.width
        guard width > 0 else { return }

        // 全屏任意位置都切换工具栏显隐（翻页靠滑动）
        _ = width
        onInteraction?(.tapCenter)
    }
}

// MARK: - 气泡在 iPhone 上也保持浮动

extension ReadiumEPUBEngine: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle {
        .none
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