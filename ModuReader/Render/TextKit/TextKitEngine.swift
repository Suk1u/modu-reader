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
    private var book: BookDescriptor?
    private var settings = ReaderSettings()
    private var totalCharacters: Int = 0

    /// 当前章纯文本。
    private var currentChapterText: String = ""
    /// 当前章分页结果。
    private var currentPagination: PaginatedChapter?
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

    init(fileStore: FileStore) {
        self.fileStore = fileStore
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

    // MARK: - Chapter loading

    private func loadChapter(at index: Int) async throws {
        guard let book, let chapter = chapters[safe: index] else { return }

        let text = try fileStore.readChapter(for: book.id, fileName: chapter.filePath)
        let profile = currentProfile() ?? defaultProfile()

        let pagination = await paginateOffMain(
            text: text,
            profile: profile,
            textColor: settings.theme.text,
            chapterIndex: index
        )

        currentChapterIndex = index
        currentChapterText = text
        currentPagination = pagination
        currentPageIndex = 0
        lastProfile = profile
    }

    /// 在后台队列分页，主线程只接收结果。
    ///
    /// 参数与返回值全部是 `Sendable` 值类型，满足 Swift 6 严格并发检查。
    private func paginateOffMain(
        text: String,
        profile: TypographyProfile,
        textColor: RGBColor,
        chapterIndex: Int
    ) async -> PaginatedChapter {
        await withCheckedContinuation { continuation in
            paginationQueue.async {
                let result = Paginator.paginate(
                    text: text,
                    profile: profile,
                    textColor: textColor,
                    chapterIndex: chapterIndex
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Rendering

    private func renderCurrentPage() {
        guard let pagination = currentPagination,
              let attributed = attributedText(for: pagination),
              pagination.slices.indices.contains(currentPageIndex) else {
            return
        }

        let contentSize = contentSizeForCurrentLayout()
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        // 保留当前页与前后页
        pagePool.recycle(except: [-1, 0, 1])

        for relative in [-1, 0, 1] {
            let targetIndex = currentPageIndex + relative
            guard let targetSlice = pagination.slices[safe: targetIndex] else { continue }

            let pageView = pagePool.view(for: relative, in: contentView)
            pageView.frame = contentView.bounds
            pageView.configure(
                chapterText: attributed,
                range: targetSlice.range,
                contentSize: contentSize
            )
            pageView.isHidden = relative != 0
        }
    }

    /// 让可见页贴合当前 bounds（不重新分页）。
    private func layoutVisiblePages() {
        let contentSize = contentSizeForCurrentLayout()
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        guard let attributed = attributedText(for: currentPagination) else { return }

        for relative in [-1, 0, 1] {
            let targetIndex = currentPageIndex + relative
            guard let slice = currentPagination?.slices[safe: targetIndex] else { continue }
            let pageView = pagePool.view(for: relative, in: contentView)
            pageView.frame = contentView.bounds
            pageView.configure(
                chapterText: attributed,
                range: slice.range,
                contentSize: contentSize
            )
            pageView.isHidden = relative != 0
        }
    }

    /// 构造当前章的富文本。每次渲染时按需构造，不长期持有。
    private func attributedText(for pagination: PaginatedChapter?) -> NSAttributedString? {
        guard pagination != nil, !currentChapterText.isEmpty else {
            return currentChapterText.isEmpty ? NSAttributedString(string: "") : nil
        }
        let profile = currentProfile() ?? defaultProfile()
        return NSAttributedString(
            string: currentChapterText,
            attributes: profile.attributes(textColor: settings.theme.text)
        )
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
        let color = settings.theme.text

        Task { [weak self] in
            guard let self else { return }
            let pagination = await self.paginateOffMain(
                text: text,
                profile: profile,
                textColor: color,
                chapterIndex: chapterIndex
            )
            // 分页期间用户可能已切换章节，丢弃过期结果
            guard self.currentChapterIndex == chapterIndex else { return }
            self.currentPagination = pagination
            self.lastProfile = profile
            self.currentPageIndex = pagination.pageIndex(forCharacterOffset: offset)
            self.renderCurrentPage()
        }
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
