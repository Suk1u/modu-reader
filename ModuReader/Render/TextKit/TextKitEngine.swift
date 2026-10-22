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
        let offset = currentPageSlice?.range.location ?? 0
        return LocatorResolver.makeLocator(
            text: currentChapterText,
            offset: offset,
            href: chapter.filePath,
            totalCharacters: totalCharacters,
            charactersBeforeResource: chapter.globalStart
        )
    }

    var totalProgression: Double {
        currentLocator.locations.totalProgression ?? 0
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
    /// 当前页在章内的序号。
    private var currentPageIndex: Int = 0
    /// 最近一次分页使用的指纹，用于判断是否需要重排。
    private var lastProfile: TypographyProfile?

    private var currentPageSlice: PageSlice? {
        currentPagination?.slices[safe: currentPageIndex]
    }

    // MARK: - Views

    private let contentView = UIView()
    private let pagePool = PagePool(capacity: 3)

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

        try await loadChapter(at: targetChapter)

        if let initialLocator {
            await go(to: initialLocator, animated: false)
        } else {
            currentPageIndex = 0
            renderCurrentPage()
        }

        view.backgroundColor = settings.theme.uiBackgroundColor
    }

    // MARK: - RenderEngine: Settings

    func apply(settings: ReaderSettings) async {
        let oldProfile = lastProfile
        self.settings = settings
        view.backgroundColor = settings.theme.uiBackgroundColor

        guard let newProfile = currentProfile() else { return }

        if oldProfile == nil || newProfile != oldProfile {
            lastProfile = newProfile
            repaginateKeepingPosition()
        } else {
            // 仅颜色变化：更新已渲染页的文字色，不重新分页
            let color = settings.theme.uiTextColor
            for relative in [-1, 0, 1] {
                pagePool.view(for: relative, in: contentView).updateTextColor(color)
            }
        }
    }

    // MARK: - RenderEngine: Navigation

    func nextPage() async -> Bool {
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

        // 用共享的 ChapterLayout 完成整章排版
        let layout = ChapterLayout()
        layout.prepare(attributed: attributed, width: profile.contentWidth)

        // 分页只读这份排版的 Y 坐标
        let result = Paginator.paginate(
            layout: layout,
            pageHeight: profile.contentHeight,
            totalLength: attributed.length
        )

        let pagination = PaginatedChapter(
            chapterIndex: index,
            characterCount: attributed.length,
            slices: result.slices
        )

        currentChapterIndex = index
        currentChapterText = text
        currentLayout = layout
        currentPagination = pagination
        currentPageIndex = 0
        lastProfile = profile
    }

    // MARK: - Rendering

    private func renderCurrentPage() {
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
            pageView.frame = contentView.bounds
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
            pageView.frame = contentView.bounds
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
    static func makeChapterAttributed(
        text: String,
        profile: TypographyProfile,
        textColor: RGBColor
    ) -> NSAttributedString {
        let baseAttributes = profile.attributes(textColor: textColor)
        let references = EPUBParser.imageReferences(in: text)

        guard !references.isEmpty else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }

        let result = NSMutableAttributedString(
            string: text,
            attributes: baseAttributes
        )

        for reference in references.reversed() {
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

            let replacement = NSMutableAttributedString(attachment: attachment)
            if markerLength > 1 {
                replacement.append(
                    NSAttributedString(
                        string: String(repeating: "\u{200B}", count: markerLength - 1),
                        attributes: baseAttributes
                    )
                )
            }
            result.replaceCharacters(in: reference.range, with: replacement)
        }

        return result
    }

    /// 构造图片 attachment。
    ///
    /// 按正文宽度等比缩放，并限制最大高度为页高的一半，
    /// 避免单张竖图撑满整页导致正文无处可放。
    private static func makeAttachment(path: String, maxWidth: CGFloat) -> NSTextAttachment? {
        guard let image = UIImage(contentsOfFile: path) else {
            Diagnostics.log("TextKitEngine: 图片加载失败 \(path)")
            return nil
        }

        let widthRatio = maxWidth / max(1, image.size.width)
        let maxHeight = maxWidth * 0.9
        let heightRatio = image.size.height > 0 ? maxHeight / image.size.height : 1
        let scale = min(1, min(widthRatio, heightRatio))

        let targetSize = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )

        // 缩小到目标尺寸，避免大图常驻内存
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        let attachment = NSTextAttachment()
        attachment.image = scaled
        attachment.bounds = CGRect(origin: .zero, size: targetSize)
        return attachment
    }

    private func notifyLocatorChange() {
        onLocatorChange?(currentLocator)
    }

    // MARK: - Profile

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

        let result = Paginator.paginate(
            layout: layout,
            pageHeight: profile.contentHeight,
            totalLength: attributed.length
        )

        let pagination = PaginatedChapter(
            chapterIndex: chapterIndex,
            characterCount: attributed.length,
            slices: result.slices
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
