//
//  ReaderSession.swift
//  ModuReader
//
//  一本书的阅读会话。持有引擎、设置与进度，是阅读状态的唯一所有者。
//

import Foundation
import SwiftUI
import SwiftData

/// 目录面板展示用的一条高亮标记。
struct HighlightItem: Identifiable, Hashable {
    let id: UUID
    let progression: Double
    let chapterTitle: String
    let createdAt: Date
    /// 被标记的文字，列表里直接显示它。
    let excerpt: String
    /// 该条高亮的颜色与样式。
    let tintHex: String?
    let underline: Bool
    /// 原始落点。按它能精确跳回高亮处，而不是最近的页边界。
    let locator: Locator?
}

/// 目录面板展示用的一条书签。
struct BookmarkItem: Identifiable, Hashable {
    let id: UUID
    let progression: Double
    let chapterTitle: String
    let createdAt: Date
    let locator: Locator?
}

/// 阅读会话。
///
/// 状态所有权：
/// - `settings`、`currentLocator`、`currentChapterIndex` 由本类持有。
/// - 子视图通过 `@Bindable` 读写，不得自己复制一份 `@State`。
@Observable
@MainActor
final class ReaderSession {

    // MARK: - Immutable

    let book: BookDescriptor
    let engine: any RenderEngine

    // MARK: - Observable state

    /// 阅读设置。变化时自动应用到引擎。
    var settings: ReaderSettings {
        didSet {
            guard settings != oldValue else { return }
            // 阅读方式按书记忆：变化时立即写库
            if settings.readingMode != oldValue.readingMode {
                persistReadingMode(settings.readingMode)
            }
            // 回写全局设置：外观、字号等需要跨书、跨启动记忆
            onSettingsChange?(settings)
            Task { await engine.apply(settings: settings) }
        }
    }

    /// 当前章节序号。
    private(set) var currentChapterIndex: Int = 0

    /// 当前章节标题。
    var currentChapterTitle: String {
        engine.chapters[safe: currentChapterIndex]?.title ?? book.title
    }

    /// 全书进度 0...1。
    private(set) var totalProgression: Double = 0

    /// 章节总数。
    var chapterCount: Int { engine.chapters.count }

    /// 当前页码（全书维度，1 起）。
    ///
    /// 必须是存储属性：引擎的页码是计算出来的，SwiftUI 观察不到，
    /// 只读计算属性会导致「只有点屏幕时才刷新页码」。
    private(set) var currentPageNumber: Int = 0

    /// 全书总页数。
    private(set) var totalPageCount: Int = 0

    /// 本书是否内嵌了可用字体。
    var hasBookFont: Bool { engine.hasBookFont }

    /// 当前主题。
    var theme: ReaderTheme { settings.theme }

    /// 点击中央区域时的回调（由 ReaderView 接管 chrome 显隐）。
    var onToggleChrome: (() -> Void)?

    /// 设置变化时回写全局设置（由 ReaderView 注入）。
    var onSettingsChange: (@MainActor (ReaderSettings) -> Void)?

    /// 本书的全部书签，按阅读进度排序。
    private(set) var bookmarks: [BookmarkItem] = []

    /// 本书的全部高亮标记，按阅读进度排序。
    private(set) var highlights: [HighlightItem] = []

    /// 当前页是否已加书签。
    private(set) var isBookmarked: Bool = false

    /// 刚选中、等待选择颜色的高亮。
    private(set) var pendingHighlight: Locator?
    /// 选区位置，用来给配色浮条定位。
    private(set) var pendingHighlightRect: CGRect?

    /// 跳转来源栈（撤销用）。
    private(set) var jumpBackStack: [Double] = []
    /// 被撤销掉的跳转（重做用）。
    private(set) var jumpForwardStack: [Double] = []
    /// 跳转按钮的过期时间。超过后自动隐藏。
    private var jumpExpiry: Date?

    var canReturnToJumpOrigin: Bool { !jumpBackStack.isEmpty }
    var canRedoJump: Bool { !jumpForwardStack.isEmpty }

    /// 本章还剩多少页。引擎给不出章节页码区间时返回 nil。
    private(set) var chapterRemainingPages: Int?

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private var progressEntity: ProgressEntity?
    private var bookEntity: BookEntity?
    private var bookmarkEntities: [BookmarkEntity] = []
    private var highlightEntities: [HighlightEntity] = []
    /// 页码去抖：滚动过程中不刷数字，稳定后才提交。
    private var pendingPage: Int = 0
    private var pageStableSince = Date()
    /// 250ms 心跳：滚动时页码、进度、书签状态都要跟着走，
    /// 不能只依赖引擎的位置回调（它只在停稳时才报）。
    private var tickTask: Task<Void, Never>?
    /// 当前页与书签的判定容差（约一页）。
    private let bookmarkTolerance: Double = 0.004
    private var lastSavedAt: Date = .distantPast
    /// 进度保存的最小间隔。
    private let saveInterval: TimeInterval = 1.0
    /// 进度界面刷新的最小间隔。
    ///
    /// 滚动模式下位置回调每秒触发几十次，每次都写 @Observable 属性
    /// 会让 SwiftUI 持续重绘底部进度条，直接表现为滚动卡顿。
    private let publishInterval: TimeInterval = 0.12
    private var lastPublishAt: Date = .distantPast

    // MARK: - Init

    init(
        book: BookDescriptor,
        engine: any RenderEngine,
        settings: ReaderSettings,
        modelContext: ModelContext
    ) {
        self.book = book
        self.engine = engine
        self.settings = settings
        self.modelContext = modelContext
    }

    // MARK: - Lifecycle

    /// 加载书籍。
    func start() async throws {
        // 恢复该书上次使用的阅读方式（在引擎加载前应用，避免先按默认模式排版）
        if let saved = loadSavedReadingMode() {
            settings.readingMode = saved
        }

        let initialLocator = loadSavedLocator()

        engine.onLocatorChange = { [weak self] locator in
            guard let self else { return }
            self.handleLocatorChange(locator)
        }

        engine.onInteraction = { [weak self] interaction in
            guard let self else { return }
            self.handleInteraction(interaction)
        }

        try await engine.load(
            book: book,
            initialLocator: initialLocator,
            settings: settings
        )

        currentChapterIndex = engine.currentChapterIndex
        totalProgression = engine.totalProgression
        reloadBookmarks()
        reloadHighlights()
        refreshPageMetrics()
        startLiveUpdates()
    }

    /// 保存进度。离开阅读器、进入后台时调用。
    func saveProgress() async {
        let locator = engine.currentLocator
        let progression = engine.totalProgression
        persist(locator: locator, progression: progression, force: true)
    }

    // MARK: - Navigation

    func nextPage() {
        Task { await engine.nextPage() }
    }

    func previousPage() {
        Task { await engine.previousPage() }
    }

    func nextChapter() {
        Task {
            await engine.nextChapter()
            syncChapterState()
        }
    }

    func previousChapter() {
        Task {
            await engine.previousChapter()
            syncChapterState()
        }
    }

    func goToChapter(_ index: Int) {
        Task {
            await engine.goToChapter(at: index)
            syncChapterState()
        }
    }

    func seek(toProgression progression: Double) {
        // 直接把全书进度交给引擎解析。
        //
        // 不再用「字符总数 × 进度 → 章节 + 章内偏移」反查：
        // Readium 引擎的 Chapter 里 globalStart / characterCount 是占位值
        // （WebKit 排版没有字符偏移概念），据此换算会得到错误位置，
        // 表现为「进度条拖到中间无效」。
        let target = max(0, min(1, progression))
        let locator = Locator(
            href: "",
            locations: Locations(totalProgression: target)
        )

        Task {
            await engine.go(to: locator, animated: false)
            syncChapterState()
        }
    }

    // MARK: - 跳转历史

    /// 记录一次跳转前的落点。
    private func recordJump() {
        jumpBackStack.append(engine.totalProgression)
        jumpForwardStack.removeAll()
        // 跳转按钮只在「刚跳完」有意义，一分钟后自动消失
        jumpExpiry = Date().addingTimeInterval(60)
    }

    /// 跳转到章节，并记下跳转前的位置。
    func goToChapterWithHistory(_ index: Int) {
        recordJump()
        goToChapter(index)
    }

    /// 按进度跳转，并记下跳转前的位置。
    func seekWithHistory(toProgression progression: Double) {
        recordJump()
        seek(toProgression: progression)
    }

    /// 从新到旧的跳转历史，供长按菜单展示。
    struct JumpEntry: Identifiable {
        let id: Int
        let index: Int
        let page: Int
    }

    var jumpEntries: [JumpEntry] {
        jumpBackStack.enumerated().reversed().map { index, progression in
            JumpEntry(id: index, index: index, page: pageNumber(atProgression: progression))
        }
    }

    /// 跳到历史里的某一项，并把之后的历史丢弃。
    func jump(to index: Int) {
        guard jumpBackStack.indices.contains(index) else { return }
        let target = jumpBackStack[index]
        jumpBackStack.removeSubrange(index...)
        jumpForwardStack.append(engine.totalProgression)
        jumpExpiry = Date().addingTimeInterval(60)
        seek(toProgression: target)
    }

    /// 撤销上一次跳转。
    func returnToJumpOrigin() {
        guard let origin = jumpBackStack.popLast() else { return }
        jumpForwardStack.append(engine.totalProgression)
        jumpExpiry = Date().addingTimeInterval(60)
        seek(toProgression: origin)
    }

    /// 重做被撤销的跳转。
    func redoJump() {
        guard let target = jumpForwardStack.popLast() else { return }
        jumpBackStack.append(engine.totalProgression)
        jumpExpiry = Date().addingTimeInterval(60)
        seek(toProgression: target)
    }

    /// 按一条标记（书签 / 高亮）的原始落点跳转。
    ///
    /// 按进度跳只能落到最近的页边界，高亮会偏出去；用 locator
    /// 才能带着文本引用回到确切位置。
    func goToMark(_ locator: Locator?, fallbackProgression: Double, center: Bool = false) {
        recordJump()
        guard let locator, !locator.href.isEmpty else {
            seek(toProgression: fallbackProgression)
            return
        }
        Task {
            await engine.go(to: locator, animated: false)
            syncChapterState()
            if center {
                engine.centerCurrentPosition(at: locator)
            }
        }
    }

    /// 指定全书进度所在的章节标题。
    func chapterTitle(atProgression progression: Double) -> String {
        engine.chapterTitle(atProgression: progression) ?? currentChapterTitle
    }

    /// 章节起始页码（1 起）。算不出来时返回 nil。
    func pageNumber(forChapter index: Int) -> Int? {
        engine.pageNumber(forChapter: index)
    }

    /// 进度换算成页码（1 起）。
    func pageNumber(atProgression progression: Double) -> Int {
        guard totalPageCount > 0 else { return 0 }
        let page = Int((min(max(progression, 0), 1) * Double(totalPageCount)).rounded())
        return min(max(page, 1), totalPageCount)
    }

    // MARK: - 书签

    /// 当前页是否已加书签（按容差匹配，跳转后自然落到新页面）。
    private func syncBookmarkState() {
        let current = engine.totalProgression
        let value = bookmarks.contains { abs($0.progression - current) < bookmarkTolerance }
        if value != isBookmarked {
            isBookmarked = value
        }
    }

    /// 在当前页添加 / 移除书签。
    ///
    /// 判定以「当前落点」为准：跳转之后再点，书签就落在跳转后的页面。
    func toggleBookmark() {
        let current = engine.totalProgression

        if let existing = bookmarkEntities.first(where: {
            abs($0.totalProgression - current) < bookmarkTolerance
        }) {
            modelContext.delete(existing)
        } else {
            guard let data = try? JSONEncoder().encode(engine.currentLocator) else { return }
            let entity = BookmarkEntity(
                locatorJSON: data,
                totalProgression: current,
                chapterTitle: currentChapterTitle
            )
            entity.book = bookEntity ?? fetchBookEntity()
            modelContext.insert(entity)
        }

        try? modelContext.save()
        reloadBookmarks()
    }

    /// 批量删除书签（目录面板的多选删除）。
    func deleteBookmarks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for entity in bookmarkEntities where ids.contains(entity.id) {
            modelContext.delete(entity)
        }
        try? modelContext.save()
        reloadBookmarks()
    }

    private func reloadBookmarks() {
        let bookID = book.id
        let descriptor = FetchDescriptor<BookmarkEntity>(
            predicate: #Predicate { $0.book?.id == bookID },
            sortBy: [SortDescriptor(\.totalProgression)]
        )
        let entities = (try? modelContext.fetch(descriptor)) ?? []
        bookmarkEntities = entities
        bookmarks = entities.map {
            BookmarkItem(
                id: $0.id,
                progression: $0.totalProgression,
                chapterTitle: $0.chapterTitle,
                createdAt: $0.createdAt,
                locator: $0.locator
            )
        }
        syncBookmarkState()
    }

    // MARK: - 高亮标记

    /// 选中文字后先挂起，等用户选完颜色 / 下划线再落库。
    private func addHighlight(at locator: Locator, rect: CGRect?) {
        pendingHighlight = locator
        pendingHighlightRect = rect
    }

    func cancelPendingHighlight() {
        pendingHighlight = nil
        pendingHighlightRect = nil
    }

    /// 用选定样式保存挂起的高亮。
    func commitHighlight(tintHex: String?, underline: Bool) {
        guard let locator = pendingHighlight,
              let data = try? JSONEncoder().encode(locator) else { return }
        pendingHighlight = nil
        pendingHighlightRect = nil

        let progression = locator.locations.totalProgression ?? engine.totalProgression
        let entity = HighlightEntity(
            locatorJSON: data,
            totalProgression: progression,
            chapterTitle: chapterTitle(atProgression: progression),
            excerpt: locator.text?.highlight ?? "",
            tintHex: tintHex,
            underline: underline
        )
        entity.book = bookEntity ?? fetchBookEntity()
        modelContext.insert(entity)
        try? modelContext.save()

        reloadHighlights()
    }

    /// 批量删除高亮标记。
    func deleteHighlights(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for entity in highlightEntities where ids.contains(entity.id) {
            modelContext.delete(entity)
        }
        try? modelContext.save()
        reloadHighlights()
    }

    private func reloadHighlights() {
        let bookID = book.id
        let descriptor = FetchDescriptor<HighlightEntity>(
            predicate: #Predicate { $0.book?.id == bookID },
            sortBy: [SortDescriptor(\.totalProgression)]
        )
        let entities = (try? modelContext.fetch(descriptor)) ?? []
        highlightEntities = entities
        highlights = entities.map {
            HighlightItem(
                id: $0.id,
                progression: $0.totalProgression,
                chapterTitle: $0.chapterTitle,
                createdAt: $0.createdAt,
                excerpt: $0.excerpt,
                tintHex: $0.tintHex,
                underline: $0.underline ?? false,
                locator: $0.locator
            )
        }

        // 交给渲染引擎画到正文上
        let marks: [HighlightMark] = entities.compactMap { entity in
            guard let locator = entity.locator else { return nil }
            return HighlightMark(
                id: entity.id,
                locator: locator,
                tintHex: entity.tintHex,
                underline: entity.underline ?? false
            )
        }
        engine.applyHighlights(marks)
    }

    // MARK: - 实时刷新

    /// 250ms 心跳。
    ///
    /// 引擎的位置回调只在停稳时可靠，滚动过程中的页码、进度条、
    /// 当前章节都得靠这里主动轮询，否则会出现「停下才更新」。
    private func startLiveUpdates() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task<Never, Never>.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// 停止心跳。视图消失时调用。
    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        // 进度用滚动位置推算，滚动过程中连续跟进
        let live = engine.liveProgression
        if abs(live - totalProgression) > 0.0005 {
            totalProgression = live
        }

        let total = engine.totalPageCountValue
        if total != totalPageCount { totalPageCount = total }

        if let chapter = engine.chapterIndex(atProgression: live),
           chapter != currentChapterIndex {
            currentChapterIndex = chapter
        }

        // 页码：滚动中保持上一个确切值，稳定 350ms 后才换成新数字
        if totalPageCount > 0 {
            let livePage = min(
                max(Int((live * Double(totalPageCount)).rounded()), 1),
                totalPageCount
            )
            if livePage != pendingPage {
                pendingPage = livePage
                pageStableSince = Date()
            } else if livePage != currentPageNumber,
                      Date().timeIntervalSince(pageStableSince) > 0.5 {
                currentPageNumber = livePage
            }
        }

        let remaining: Int? = {
            guard currentPageNumber > 0, let range = engine.chapterPageRange() else { return nil }
            return max(0, range.upperBound - currentPageNumber)
        }()
        if remaining != chapterRemainingPages { chapterRemainingPages = remaining }

        syncBookmarkState()

        // 跳转按钮一分钟后自动消失
        if let expiry = jumpExpiry, Date() >= expiry {
            jumpExpiry = nil
            jumpBackStack.removeAll()
            jumpForwardStack.removeAll()
        }
    }
    // MARK: - Search

    /// 在全书范围搜索。
    func search(_ query: String) async -> [SearchResult] {
        await engine.search(query)
    }

    /// 跳转到一条搜索结果。
    func go(to result: SearchResult) {
        let chapter = engine.chapters[safe: result.chapterIndex]
        // WebKit 引擎给的是「资源 + 资源内进度」，比字符偏移可靠
        let href = result.href ?? chapter?.filePath ?? ""
        let locator = Locator(
            href: href,
            locations: Locations(
                progression: result.progression,
                charOffset: result.href == nil ? result.charOffset : nil,
                page: nil
            ),
            text: TextQuote(highlight: result.matchedText)
        )

        Task {
            await engine.go(to: locator, animated: false)
            syncChapterState()
        }
    }

    // MARK: - 阅读方式持久化

    /// 读取该书保存的阅读方式。
    private func loadSavedReadingMode() -> ReadingMode? {
        let bookID = book.id
        let descriptor = FetchDescriptor<BookEntity>(
            predicate: #Predicate { $0.id == bookID }
        )
        guard let entity = try? modelContext.fetch(descriptor).first,
              let raw = entity.readingModeRaw else { return nil }
        return ReadingMode(rawValue: raw)
    }

    /// 保存该书当前阅读方式。
    private func persistReadingMode(_ mode: ReadingMode) {
        let bookID = book.id
        let descriptor = FetchDescriptor<BookEntity>(
            predicate: #Predicate { $0.id == bookID }
        )
        guard let entity = try? modelContext.fetch(descriptor).first else { return }
        entity.readingModeRaw = mode.rawValue
        try? modelContext.save()
    }

    // MARK: - Progress persistence

    private func loadSavedLocator() -> Locator? {
        let bookID = book.id
        let descriptor = FetchDescriptor<ProgressEntity>(
            predicate: #Predicate { $0.book?.id == bookID }
        )
        guard let entity = try? modelContext.fetch(descriptor).first else { return nil }
        progressEntity = entity
        return entity.locator
    }

    private func handleLocatorChange(_ locator: Locator) {
        // 章节变化立即同步（用于底部章节名）
        let chapterIndex = engine.currentChapterIndex
        if chapterIndex != currentChapterIndex {
            currentChapterIndex = chapterIndex
        }

        // 进度百分比按固定间隔刷新，避免滚动时高频重绘
        let now = Date()
        if now.timeIntervalSince(lastPublishAt) >= publishInterval {
            lastPublishAt = now
            totalProgression = engine.totalProgression
            refreshPageMetrics()
        }

        persist(locator: locator, progression: engine.totalProgression, force: false)
    }

    private func persist(locator: Locator, progression: Double, force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(lastSavedAt) < saveInterval {
            return
        }
        lastSavedAt = now

        guard let data = try? JSONEncoder().encode(locator),
              let entity = ensureProgressEntity() else { return }

        entity.locatorJSON = data
        entity.totalProgression = progression
        entity.updatedAt = now

        try? modelContext.save()
    }

    private func fetchBookEntity() -> BookEntity? {
        let bookID = book.id
        let descriptor = FetchDescriptor<BookEntity>(
            predicate: #Predicate { $0.id == bookID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// 取得（必要时创建）本书的进度实体。
    @discardableResult
    private func ensureProgressEntity() -> ProgressEntity? {
        if let progressEntity { return progressEntity }

        let bookID = book.id
        let descriptor = FetchDescriptor<BookEntity>(
            predicate: #Predicate { $0.id == bookID }
        )
        guard let bookEntity = try? modelContext.fetch(descriptor).first else { return nil }
        self.bookEntity = bookEntity

        let entity = ProgressEntity(
            locatorJSON: Data(),
            totalProgression: engine.totalProgression,
            updatedAt: Date()
        )
        entity.book = bookEntity
        modelContext.insert(entity)
        progressEntity = entity
        return entity
    }

    // MARK: - Interaction

    private func handleInteraction(_ interaction: ReaderInteraction) {
        switch interaction {
        case .tapLeft:
            previousPage()
        case .tapRight:
            nextPage()
        case .tapCenter:
            onToggleChrome?()
        case .selectionChanged:
            break
        case .highlight(let locator, let rect):
            addHighlight(at: locator, rect: rect)
        }
    }

    private func syncChapterState() {
        currentChapterIndex = engine.currentChapterIndex
        totalProgression = engine.totalProgression
        refreshPageMetrics()
    }

    /// 把引擎的计算值搬进可观察属性。
    private func refreshPageMetrics() {
        totalPageCount = engine.totalPageCountValue

        if currentPageNumber > 0, let range = engine.chapterPageRange() {
            chapterRemainingPages = max(0, range.upperBound - currentPageNumber)
        } else {
            chapterRemainingPages = nil
        }
    }
}
