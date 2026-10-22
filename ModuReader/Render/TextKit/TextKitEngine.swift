//
//  TextKitEngine.swift
//  ModuReader
//
//  TextKit 2 文字引擎。承载 TXT / Markdown 的分页阅读。
//

import UIKit

/// TextKit 2 文字引擎。
///
/// 结构：
/// ```
/// TextKitEngine (UIViewController)
/// └── contentView
///     └── PagePool（当前页 ±1 的 TextPageView）
/// ```
///
/// 线程模型：
/// - 所有 UI 与状态在主线程。
/// - 分页在 `paginationQueue` 上执行，只接收 `String` + `TypographyProfile` + `RGBColor`
///   这类 `Sendable` 值类型，返回 `PaginatedChapter` 值类型。
///   `NSAttributedString` 与 TextKit 对象**不跨越队列边界**。
@MainActor
final class TextKitEngine: UIViewController, RenderEngine {

    // MARK: - RenderEngine

    let kind: EngineKind = .textKit

    var onLocatorChange: ((Locator) -> Void)?
    var onInteraction: ((ReaderInteraction) -> Void)?

    private(set) var chapters: [Chapter] = []
    private(set) var currentChapterIndex: Int = 0

    var currentLocator: Locator {
        guard let chapter = chapters[safe: currentChapterIndex] else {
            return Locator(href: "")
        }

        // 滚动模式没有「页」，按滚动比例折算字符偏移
        let offset: Int
        if isScrollMode {
            let length = (currentChapterText as NSString).length
            offset = Int(scrollFraction() * Double(length))
        } else {
            offset = currentPageSlice?.range.location ?? 0
        }
        return LocatorResolver.makeLocator(
            text: currentChapterText,
            offset: offset,
            href: chapter.filePath,
            totalCharacters: totalCharacters,
            charactersBeforeResource: chapter.globalStart
        )
    }

    /// 全书进度。
    ///
    /// 分页模式按页数算；滚动模式按滚动偏移算。
    var totalProgression: Double {
        guard totalPageCount > 0 else { return 0 }
        let pagesBefore = chapterPageCounts.prefix(currentChapterIndex).reduce(0, +)

        if isScrollMode {
            // 滚动模式：按本章内偏移折算成页
            let chapterPages = chapterPageCounts[safe: currentChapterIndex] ?? 1
            let fraction = scrollFraction()
            let pageInChapter = Int(fraction * Double(chapterPages))
            let pageNumber = pagesBefore + min(chapterPages, pageInChapter + 1)
            return min(1, max(0, Double(pageNumber) / Double(totalPageCount)))
        }

        let currentPageNumber = pagesBefore + currentPageIndex + 1
        return min(1, max(0, Double(currentPageNumber) / Double(totalPageCount)))
    }

    /// 全书总页数（对外只读）。
    var totalPageCountValue: Int { totalPageCount }

    /// 本书是否内嵌了可用字体。
    var hasBookFont: Bool { bookFontName != nil }

    /// 当前页码（全书维度，1 起）。
    var currentPageNumber: Int {
        let pagesBefore = chapterPageCounts.prefix(currentChapterIndex).reduce(0, +)
        if isScrollMode {
            let chapterPages = chapterPageCounts[safe: currentChapterIndex] ?? 1
            let pageInChapter = Int(scrollFraction() * Double(chapterPages))
            return pagesBefore + min(chapterPages, pageInChapter + 1)
        }
        return pagesBefore + currentPageIndex + 1
    }

    /// 当前滚动位置在本章内的比例（0...1）。
    private func scrollFraction() -> Double {
        guard let scrollView else { return 0 }
        let scrollable = scrollView.contentSize.height
            + scrollView.contentInset.top
            + scrollView.contentInset.bottom
            - scrollView.bounds.height
        guard scrollable > 1 else { return 1 }
        let offset = scrollView.contentOffset.y + scrollView.contentInset.top
        return min(1, max(0, Double(offset / scrollable)))
    }

    // MARK: - State

    private let fileStore: FileStore
    /// 分页缓存。为 nil 时退化为每次都重新分页（缓存目录不可写）。
    private let pageCache: PageIndexCache?
    private var book: BookDescriptor?
    private var settings = ReaderSettings()
    private var totalCharacters: Int = 0

    /// 当前章纯文本（含图片标记，用于定位图片）。
    private var currentChapterText: String = ""

    /// 当前章分页结果。
    private var currentPagination: PaginatedChapter?
    /// 当前章的整章排版。分页与渲染共用。
    private var currentLayout: ChapterLayout?

    /// 每章的页数（索引 = 章节序号）。
    ///
    /// 用于计算「全书总页数」与「当前第几页」。
    /// 在 `load` 时一次性算好，翻页时只做加法。
    private var chapterPageCounts: [Int] = []
    /// 全书总页数。
    private var totalPageCount: Int = 0

    /// 本书注册的字体。
    private let fontRegistry = BookFontRegistry()
    /// 书籍自带的正文主字体名（nil 表示用系统字体）。
    private var bookFontName: String?
    /// 当前页在章内的序号。
    private var currentPageIndex: Int = 0
    /// 最近一次分页使用的指纹，用于判断是否需要重排。
    private var lastProfile: TypographyProfile?
    /// 上一次的阅读模式，用于检测切换。
    private var oldReadingMode: ReadingMode = .paged
    /// 当前章的富文本，供重新排版时复用。
    private var currentAttributed: NSAttributedString?

    private var currentPageSlice: PageSlice? {
        currentPagination?.slices[safe: currentPageIndex]
    }

    // MARK: - Views

    private let contentView = UIView()
    private let pagePool = PagePool(capacity: 3)

    /// 滚动模式下的滚动容器。
    private var scrollView: UIScrollView?
    /// 滚动模式下的正文画布。
    private var scrollContentView: ScrollChapterView?

    /// 当前是否滚动模式。
    private var isScrollMode: Bool { settings.readingMode == .scroll }

    // MARK: - Queues

    /// 分页专用串行队列。
    private let paginationQueue = DispatchQueue(
        label: "com.modu.reader.pagination",
        qos: .userInitiated
    )

    // MARK: - Init

    init(fileStore: FileStore, pageCache: PageIndexCache? = nil) {
        self.fileStore = fileStore
        self.pageCache = pageCache
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = settings.theme.uiBackgroundColor
        contentView.frame = view.bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.backgroundColor = .clear
        view.addSubview(contentView)
        installGestures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // 首次拿到真实尺寸时，重新估算全书页数
        if !chapters.isEmpty, totalPageCount == 0 {
            estimatePageCounts()
        }

        // 滚动模式：同步滚动容器与画布尺寸
        if isScrollMode, let layout = currentLayout, let profile = currentProfile() {
            let previousProfile = lastProfile
            if previousProfile != profile {
                lastProfile = profile
                layout.prepareFull(
                    attributed: currentAttributed ?? NSAttributedString(string: currentChapterText),
                    width: profile.contentWidth
                )
            }
            showScrollContent(layout: layout, profile: profile)
            return
        }

        // 尺寸变化 → 重新分页
        guard let profile = currentProfile() else { return }
        guard lastProfile != profile else {
            // 尺寸没变，只需让当前页重新贴合新 bounds
            layoutVisiblePages()
            return
        }
        lastProfile = profile
        repaginateKeepingPosition()
    }

    // MARK: - RenderEngine: Load

    func load(
        book: BookDescriptor,
        initialLocator: Locator?,
        settings: ReaderSettings
    ) async throws {
        self.book = book
        self.settings = settings
        self.oldReadingMode = settings.readingMode
        self.totalCharacters = book.totalCharacters

        let index = try fileStore.readIndex(for: book.id)
        self.chapters = index.chapters.map {
            Chapter(
                id: $0.index,
                title: $0.title,
                filePath: $0.file,
                globalStart: $0.globalStart,
                characterCount: $0.characterCount
            )
        }
        self.totalCharacters = index.totalCharacters

        let targetChapter: Int
        if let initialLocator,
           let chapterIndex = chapters.firstIndex(where: { $0.filePath == initialLocator.href }) {
            targetChapter = chapterIndex
        } else {
            targetChapter = 0
        }

        // 注册书籍自带字体
        fontRegistry.registerFonts(in: fileStore.bookDirectory(for: book.id))
        bookFontName = fontRegistry.primaryFontName

        // 预算全书页数（供进度条与页码显示）
        estimatePageCounts()

        try await loadChapter(at: targetChapter)

        if let initialLocator {
            await go(to: initialLocator, animated: false)
        } else {
            currentPageIndex = 0
            renderCurrentPage()
        }

        view.backgroundColor = settings.theme.uiBackgroundColor
    }

    /// 预算每章页数与全书总页数。
    ///
    /// 用 CTFramesetter 快速估算：只算字符数除以「每页容量」，
    /// 不做真实排版 —— 真实排版在 `loadChapter` 里按章进行。
    ///
    /// 为什么不用真实分页：
    /// 一本书可能有几百章，逐章真实排版要几十秒。
    /// 进度条只需要近似值，误差在 1-2 页内用户无感。
    private func estimatePageCounts() {
        // 此时 view 可能还没完成布局（bounds 为 0），
        // currentProfile() 会返回 nil。用兜底尺寸估算，
        // 布局完成后 viewDidLayoutSubviews 会重新估算。
        let profile = currentProfile() ?? TypographyProfile(
            fontFamily: settings.fontFamily,
            bookFontName: settings.useBookFont ? bookFontName : nil,
            fontSize: CGFloat(settings.fontSize),
            lineHeightMultiple: CGFloat(settings.lineHeightMultiple),
            paragraphSpacing: CGFloat(settings.paragraphSpacing),
            firstLineIndent: settings.firstLineIndent,
            letterSpacing: CGFloat(settings.letterSpacing),
            contentWidth: 340,
            contentHeight: 600
        )

        // 每页大致能放多少字：正文面积 / 单字面积
        let lineHeight = profile.fontSize * profile.lineHeightMultiple
        let charWidth = profile.fontSize
        let linesPerPage = max(1, Int(profile.contentHeight / max(1, lineHeight)))
        let charsPerLine = max(1, Int(profile.contentWidth / max(1, charWidth)))
        let charsPerPage = max(1, linesPerPage * charsPerLine)

        chapterPageCounts = chapters.map { chapter in
            max(1, Int(ceil(Double(chapter.characterCount) / Double(charsPerPage))))
        }
        totalPageCount = chapterPageCounts.reduce(0, +)

        Diagnostics.log("分页估算: \(charsPerPage) 字/页, 共 \(totalPageCount) 页, \(chapters.count) 章")
    }

    // MARK: - RenderEngine: Settings

    func apply(settings: ReaderSettings) async {
        let oldProfile = lastProfile
        self.settings = settings
        view.backgroundColor = settings.theme.uiBackgroundColor

        guard let newProfile = currentProfile() else { return }

        // 阅读模式切换 → 重建视图层级
        if settings.readingMode != oldReadingMode {
            oldReadingMode = settings.readingMode
            Task { try? await loadChapter(at: currentChapterIndex) }
            return
        }

        if isScrollMode {
            // 滚动模式：重新排版并刷新画布
            guard let layout = currentLayout, let attributed = currentAttributed else { return }
            layout.prepareFull(attributed: attributed, width: newProfile.contentWidth)
            showScrollContent(layout: layout, profile: newProfile)
            return
        }

        if oldProfile == nil || newProfile != oldProfile {
            lastProfile = newProfile
            repaginateKeepingPosition()
        } else {
            // 仅颜色变化：更新共享排版的文字色，然后重绘各页。
            // 不重新分页 —— 颜色不影响行几何。
            currentLayout?.updateTextColor(settings.theme.uiTextColor)
            for relative in [-1, 0, 1] {
                pagePool.view(for: relative, in: contentView).refresh()
            }
        }
    }

    // MARK: - RenderEngine: Navigation

    func nextPage() async -> Bool {
        if isScrollMode {
            return await scrollByPage(forward: true)
        }

        guard let pagination = currentPagination else { return false }

        if currentPageIndex + 1 < pagination.pageCount {
            currentPageIndex += 1
            renderCurrentPage()
            notifyLocatorChange()
            return true
        }

        // 章末 → 下一章
        guard currentChapterIndex + 1 < chapters.count else { return false }
        try? await loadChapter(at: currentChapterIndex + 1)
        currentPageIndex = 0
        renderCurrentPage()
        notifyLocatorChange()
        return true
    }

    func previousPage() async -> Bool {
        if isScrollMode {
            return await scrollByPage(forward: false)
        }

        if currentPageIndex > 0 {
            currentPageIndex -= 1
            renderCurrentPage()
            notifyLocatorChange()
            return true
        }

        guard currentChapterIndex > 0 else { return false }
        try? await loadChapter(at: currentChapterIndex - 1)
        currentPageIndex = max(0, (currentPagination?.pageCount ?? 1) - 1)
        renderCurrentPage()
        notifyLocatorChange()
        return true
    }

    /// 滚动模式下按「一屏」滚动。到边界时切换章节。
    private func scrollByPage(forward: Bool) async -> Bool {
        guard let scrollView else { return false }

        let pageHeight = max(1, scrollView.bounds.height - scrollView.contentInset.top)
        let maxOffset = scrollView.contentSize.height
            + scrollView.contentInset.bottom
            - scrollView.bounds.height
        let current = scrollView.contentOffset.y

        let target = current + (forward ? pageHeight : -pageHeight)

        if forward, target > maxOffset + 1 {
            // 已到本章末尾 → 下一章
            guard currentChapterIndex + 1 < chapters.count else { return false }
            try? await loadChapter(at: currentChapterIndex + 1)
            scrollView.setContentOffset(
                CGPoint(x: 0, y: -scrollView.contentInset.top),
                animated: false
            )
            notifyLocatorChange()
            return true
        }

        if !forward, target < -scrollView.contentInset.top - 1 {
            // 已到本章开头 → 上一章
            guard currentChapterIndex > 0 else { return false }
            try? await loadChapter(at: currentChapterIndex - 1)
            // 落到上一章末尾
            let bottom = scrollView.contentSize.height
                + scrollView.contentInset.bottom
                - scrollView.bounds.height
            scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            notifyLocatorChange()
            return true
        }

        let clamped = min(maxOffset, max(-scrollView.contentInset.top, target))
        scrollView.setContentOffset(CGPoint(x: 0, y: clamped), animated: true)
        notifyLocatorChange()
        return true
    }

    func nextChapter() async {
        guard currentChapterIndex + 1 < chapters.count else { return }
        try? await loadChapter(at: currentChapterIndex + 1)
        currentPageIndex = 0
        renderCurrentPage()
        notifyLocatorChange()
    }

    func previousChapter() async {
        guard currentChapterIndex > 0 else { return }
        try? await loadChapter(at: currentChapterIndex - 1)
        currentPageIndex = 0
        renderCurrentPage()
        notifyLocatorChange()
    }

    func goToChapter(at index: Int) async {
        guard index >= 0, index < chapters.count else { return }
        try? await loadChapter(at: index)
        currentPageIndex = 0
        renderCurrentPage()
        notifyLocatorChange()
    }

    func go(to locator: Locator, animated: Bool) async {
        guard let chapterIndex = chapters.firstIndex(where: { $0.filePath == locator.href }) else {
            return
        }

        if chapterIndex != currentChapterIndex {
            try? await loadChapter(at: chapterIndex)
        }

        let offset = LocatorResolver.resolve(locator, in: currentChapterText)
        let pageIndex = currentPagination?.pageIndex(forCharacterOffset: offset) ?? 0
        currentPageIndex = pageIndex
        renderCurrentPage()
        notifyLocatorChange()
    }

    func visibleText() -> String? {
        guard let slice = currentPageSlice else { return nil }
        let ns = currentChapterText as NSString
        guard slice.range.location + slice.range.length <= ns.length else { return nil }
        return ns.substring(with: slice.range)
    }

    // MARK: - Search

    /// 全书搜索。
    ///
    /// 逐章在后台队列扫描，每章之间检查取消状态。
    /// 单章命中数上限 100 条，全书上限 500 条，防止超长书产生海量结果。
    func search(_ query: String) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let bookID = book?.id else { return [] }

        let chapterList = chapters
        let fileStore = self.fileStore

        return await withCheckedContinuation { continuation in
            paginationQueue.async {
                var results: [SearchResult] = []
                let perChapterLimit = 100
                let totalLimit = 500

                for chapter in chapterList {
                    if results.count >= totalLimit { break }
                    if Task.isCancelled { break }

                    guard let text = try? fileStore.readChapter(
                        for: bookID,
                        fileName: chapter.filePath
                    ) else { continue }

                    // NSString 不是 Sendable。在闭包内用局部变量承载，
                    // 不跨队列传递，满足严格并发检查。
                    let ns = text as NSString
                    var searchStart = 0
                    var hitsInChapter = 0

                    while searchStart < ns.length, hitsInChapter < perChapterLimit {
                        let searchRange = NSRange(
                            location: searchStart,
                            length: ns.length - searchStart
                        )
                        let found = ns.range(
                            of: trimmed,
                            options: [.caseInsensitive, .diacriticInsensitive],
                            range: searchRange
                        )
                        guard found.location != NSNotFound else { break }

                        let start = max(0, found.location - 24)
                        let end = min(ns.length, found.location + found.length + 24)
                        let rawContext = ns.substring(
                            with: NSRange(location: start, length: end - start)
                        )
                        let context = rawContext
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespaces)

                        results.append(
                            SearchResult(
                                chapterIndex: chapter.id,
                                chapterTitle: chapter.title,
                                charOffset: found.location,
                                context: context,
                                matchedText: ns.substring(with: found)
                            )
                        )

                        hitsInChapter += 1
                        searchStart = found.location + max(1, found.length)
                    }
                }

                continuation.resume(returning: results)
            }
        }
    }

    // MARK: - Chapter loading

    private func loadChapter(at index: Int) async throws {
        guard let book, let chapter = chapters[safe: index] else { return }

        let text = try fileStore.readChapter(for: book.id, fileName: chapter.filePath)
        let profile = currentProfile() ?? defaultProfile()

        // 构造带图片 attachment 的富文本 —— 分页与渲染共用这一份。
        let attributed = Self.makeChapterAttributed(
            text: text,
            profile: profile,
            textColor: settings.theme.text
        )

        // 用共享的 ChapterLayout 完成排版
        let layout = ChapterLayout()

        if isScrollMode {
            // 滚动模式需要知道内容总高度
            layout.prepareFull(attributed: attributed, width: profile.contentWidth)
        } else {
            layout.prepare(attributed: attributed, width: profile.contentWidth)
        }

        currentChapterIndex = index
        currentChapterText = text
        currentAttributed = attributed
        currentLayout = layout
        currentPageIndex = 0
        lastProfile = profile

        if isScrollMode {
            // 滚动模式不需要分页
            currentPagination = nil
            showScrollContent(layout: layout, profile: profile)
        } else {
            hideScrollContent()
            // 分页用 CTFramesetter（确定性、快），渲染用上面的 ChapterLayout
            currentPagination = Paginator.paginate(
                attributedText: attributed,
                profile: profile,
                chapterIndex: index
            )
        }
    }

    // MARK: - 滚动模式

    /// 切换到滚动模式并展示当前章。
    private func showScrollContent(layout: ChapterLayout, profile: TypographyProfile) {
        // 分页视图全部收起
        pagePool.recycle(except: [])
        for relative in [-1, 0, 1] {
            pagePool.view(for: relative, in: contentView).isHidden = true
        }

        let scroll = scrollView ?? makeScrollView()
        let canvas = scrollContentView ?? makeScrollCanvas()

        let insets = UIEdgeInsets(
            top: CGFloat(settings.verticalPadding),
            left: CGFloat(settings.horizontalPadding),
            bottom: CGFloat(settings.verticalPadding) + 24,
            right: CGFloat(settings.horizontalPadding)
        )
        scroll.frame = contentView.bounds
        scroll.contentInset = insets
        canvas.frame = CGRect(
            x: 0, y: 0,
            width: profile.contentWidth,
            height: max(1, layout.contentHeight)
        )
        canvas.configure(layout: layout, contentWidth: profile.contentWidth)
        scroll.contentSize = canvas.frame.size

        scroll.isHidden = false
        canvas.isHidden = false
    }

    private func makeScrollView() -> UIScrollView {
        let scroll = UIScrollView()
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = true
        scroll.backgroundColor = .clear
        scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never
        contentView.addSubview(scroll)
        scrollView = scroll
        return scroll
    }

    private func makeScrollCanvas() -> ScrollChapterView {
        let canvas = ScrollChapterView()
        canvas.autoresizingMask = []
        scrollView?.addSubview(canvas)
        scrollContentView = canvas
        return canvas
    }

    private func hideScrollContent() {
        scrollView?.isHidden = true
        scrollContentView?.isHidden = true
    }

    // MARK: - Rendering

    private func renderCurrentPage() {
        // 滚动模式由 UIScrollView 负责显示，不走分页渲染
        guard !isScrollMode else { return }
        guard let pagination = currentPagination,
              let layout = currentLayout,
              pagination.slices.indices.contains(currentPageIndex) else {
            return
        }

        // 保留当前页与前后页
        pagePool.recycle(except: [-1, 0, 1])

        for relative in [-1, 0, 1] {
            let targetIndex = currentPageIndex + relative
            guard let targetSlice = pagination.slices[safe: targetIndex] else { continue }

            let pageView = pagePool.view(for: relative, in: contentView)
            pageView.frame = contentFrame()
            pageView.configure(layout: layout, slice: targetSlice)
            pageView.isHidden = relative != 0
        }
    }

    /// 让可见页贴合当前 bounds（不重新分页）。
    private func layoutVisiblePages() {
        guard let layout = currentLayout else { return }

        for relative in [-1, 0, 1] {
            let targetIndex = currentPageIndex + relative
            guard let slice = currentPagination?.slices[safe: targetIndex] else { continue }
            let pageView = pagePool.view(for: relative, in: contentView)
            pageView.frame = contentFrame()
            pageView.configure(layout: layout, slice: slice)
            pageView.isHidden = relative != 0
        }
    }

    /// 构造整章富文本（含图片 attachment）。
    ///
    /// 分页与渲染共用这一份，保证字符数与行几何完全一致。
    ///
    /// 图片处理：把 U+FFFC 图片标记替换为
    /// 「1 个 NSTextAttachment + (N-1) 个零宽空格」，
    /// 保持文本长度不变 —— 分页区间基于原始长度计算。
    nonisolated static func makeChapterAttributed(
        text: String,
        profile: TypographyProfile,
        textColor: RGBColor
    ) -> NSAttributedString {
        let baseAttributes = profile.attributes(textColor: textColor)

        // 1. 提取字体标记并剥离，得到纯正文
        let fontRefs = EPUBParser.fontReferences(in: text)
        let plainText = EPUBParser.strippingFontMarkers(text)

        let result = NSMutableAttributedString(
            string: plainText,
            attributes: baseAttributes
        )

        // 2. 应用段落级字体
        //
        // fontRefs 的 offset 是「剥离标记后」的位置，
        // 每个标记作用于从该位置到下一个标记（或文末）的段落。
        if !fontRefs.isEmpty {
            let ns = plainText as NSString
            for (index, ref) in fontRefs.enumerated() {
                let start = min(ref.offset, ns.length)
                let end = index + 1 < fontRefs.count
                    ? min(fontRefs[index + 1].offset, ns.length)
                    : ns.length
                guard end > start else { continue }

                // 只应用到该段落的第一个换行前（字体标记是段落级的）
                let segment = ns.substring(with: NSRange(location: start, length: end - start))
                let lineLength: Int
                if let newline = segment.firstIndex(of: "\n") {
                    lineLength = segment.distance(from: segment.startIndex, to: newline)
                } else {
                    lineLength = segment.utf16.count
                }
                guard lineLength > 0 else { continue }

                let applyRange = NSRange(location: start, length: lineLength)
                if let custom = UIFont(name: ref.fontName, size: profile.fontSize) {
                    result.addAttribute(.font, value: custom, range: applyRange)
                }
            }
        }

        // 3. 处理图片标记（位置基于含标记的原文，需要重新映射）
        let imageRefs = EPUBParser.imageReferences(in: text)
        guard !imageRefs.isEmpty else { return result }

        // 计算图片标记在「剥离字体标记后」文本中的位置
        let strippedText = plainText
        let imageRefsInStripped = EPUBParser.imageReferences(in: strippedText)
        guard !imageRefsInStripped.isEmpty else { return result }

        for reference in imageRefsInStripped.reversed() {
            let markerLength = reference.range.length
            guard markerLength > 0 else { continue }

            guard let attachment = makeAttachment(
                path: reference.source,
                maxWidth: profile.contentWidth
            ) else {
                let blank = String(repeating: "\u{2007}", count: markerLength)
                result.replaceCharacters(in: reference.range, with: blank)
                continue
            }

            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            centered.firstLineHeadIndent = 0
            centered.headIndent = 0
            centered.paragraphSpacing = profile.paragraphSpacing
            centered.lineHeightMultiple = 1.0

            var imageAttributes = baseAttributes
            imageAttributes[.paragraphStyle] = centered

            let replacement = NSMutableAttributedString(
                string: "\u{FFFC}",
                attributes: imageAttributes
            )
            replacement.addAttribute(
                .attachment,
                value: attachment,
                range: NSRange(location: 0, length: 1)
            )
            if markerLength > 1 {
                replacement.append(
                    NSAttributedString(
                        string: String(repeating: "\u{200B}", count: markerLength - 1),
                        attributes: imageAttributes
                    )
                )
            }
            result.replaceCharacters(in: reference.range, with: replacement)
        }

        return result
    }

    /// 构造图片 attachment。
    ///
    /// 布局规则：
    /// - 图片独占一行（标记前后各有一个换行），宽度撑满正文宽度
    /// - 高度上限为正文宽度的 1.2 倍，避免超长竖图撑满整页
    /// - 用居中的段落样式，避免图片贴在左侧、右边留白
    nonisolated private static func makeAttachment(
        path: String,
        maxWidth: CGFloat
    ) -> NSTextAttachment? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            Diagnostics.log("TextKitEngine: 图片读取失败 \(path)")
            return nil
        }

        // 先取原始尺寸，算出等比缩放后的目标尺寸
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
        let aspect = pixelHeight / max(1, pixelWidth)

        let maxHeight = maxWidth * 1.2
        var targetWidth = maxWidth
        var targetHeight = targetWidth * aspect
        if targetHeight > maxHeight {
            targetHeight = maxHeight
            targetWidth = targetHeight / max(0.01, aspect)
        }

        let targetSize = CGSize(width: max(1, targetWidth), height: max(1, targetHeight))

        // 用 ImageIO 生成缩略图（线程安全，不加载原图到内存）
        let maxPixel = max(targetSize.width, targetSize.height) * 3
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            return nil
        }

        let attachment = NSTextAttachment()
        attachment.image = UIImage(cgImage: cgImage)
        attachment.bounds = CGRect(origin: .zero, size: targetSize)
        return attachment
    }

    private func notifyLocatorChange() {
        onLocatorChange?(currentLocator)
    }

    // MARK: - Profile

    /// 正文区域的实际矩形（已扣除四周边距）。
    ///
    /// 页面视图必须用这个 frame：文本容器宽度是扣除边距的，
    /// 若页面视图仍铺满全宽，文字会从 x=0 开始画，导致左无边距、右有大片空白。
    private func contentFrame() -> CGRect {
        contentView.bounds.inset(
            by: UIEdgeInsets(
                top: CGFloat(settings.verticalPadding),
                left: CGFloat(settings.horizontalPadding),
                bottom: CGFloat(settings.verticalPadding),
                right: CGFloat(settings.horizontalPadding)
            )
        )
    }

    private func contentSizeForCurrentLayout() -> CGSize {
        let width = contentView.bounds.width - CGFloat(settings.horizontalPadding) * 2
        let height = contentView.bounds.height - CGFloat(settings.verticalPadding) * 2
        return CGSize(width: max(1, width), height: max(1, height))
    }

    private func currentProfile() -> TypographyProfile? {
        let size = contentSizeForCurrentLayout()
        guard size.width > 1, size.height > 1 else { return nil }
        return TypographyProfile(
            fontFamily: settings.fontFamily,
            bookFontName: settings.useBookFont ? bookFontName : nil,
            fontSize: CGFloat(settings.fontSize),
            lineHeightMultiple: CGFloat(settings.lineHeightMultiple),
            paragraphSpacing: CGFloat(settings.paragraphSpacing),
            firstLineIndent: settings.firstLineIndent,
            letterSpacing: CGFloat(settings.letterSpacing),
            contentWidth: size.width,
            contentHeight: size.height
        )
    }

    private func defaultProfile() -> TypographyProfile {
        TypographyProfile(contentWidth: 320, contentHeight: 480)
    }

    /// 重新分页并保持当前字符位置。
    private func repaginateKeepingPosition() {
        guard let profile = currentProfile(), !currentChapterText.isEmpty else { return }

        let offset = currentPageSlice?.range.location ?? 0
        let chapterIndex = currentChapterIndex
        let text = currentChapterText

        // 排版与分页都在主线程完成：ChapterLayout 持有 TextKit 对象，
        // 不能跨队列。章节已限制在 12,000 字以内，这里是毫秒级。
        let attributed = Self.makeChapterAttributed(
            text: text,
            profile: profile,
            textColor: settings.theme.text
        )

        let layout = ChapterLayout()
        layout.prepare(attributed: attributed, width: profile.contentWidth)

        let pagination = Paginator.paginate(
            attributedText: attributed,
            profile: profile,
            chapterIndex: chapterIndex
        )

        currentLayout = layout
        currentPagination = pagination
        lastProfile = profile
        currentPageIndex = pagination.pageIndex(forCharacterOffset: offset)
        renderCurrentPage()
    }

    // MARK: - Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        contentView.addGestureRecognizer(tap)

        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft))
        swipeLeft.direction = .left
        contentView.addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight))
        swipeRight.direction = .right
        contentView.addGestureRecognizer(swipeRight)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        let width = contentView.bounds.width
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

    @objc private func handleSwipeLeft() {
        onInteraction?(.tapRight)
    }

    @objc private func handleSwipeRight() {
        onInteraction?(.tapLeft)
    }
}

// MARK: - Safe subscript

extension Array {
    /// 越界安全的元素访问。
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}


// MARK: - UIScrollViewDelegate

extension TextKitEngine: UIScrollViewDelegate {

    /// 滚动时上报位置变化（节流由 ReaderSession 负责）。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isScrollMode else { return }
        onLocatorChange?(currentLocator)
    }
}
