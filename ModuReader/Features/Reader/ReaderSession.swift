//
//  ReaderSession.swift
//  ModuReader
//
//  一本书的阅读会话。持有引擎、设置与进度，是阅读状态的唯一所有者。
//

import Foundation
import SwiftUI
import SwiftData

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
    var currentPageNumber: Int { engine.currentPageNumber }

    /// 全书总页数。
    var totalPageCount: Int { engine.totalPageCountValue }

    /// 本书是否内嵌了可用字体。
    var hasBookFont: Bool { engine.hasBookFont }

    /// 当前主题。
    var theme: ReaderTheme { settings.theme }

    /// 点击中央区域时的回调（由 ReaderView 接管 chrome 显隐）。
    var onToggleChrome: (() -> Void)?

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private var progressEntity: ProgressEntity?
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

    // MARK: - Search

    /// 在全书范围搜索。
    func search(_ query: String) async -> [SearchResult] {
        await engine.search(query)
    }

    /// 跳转到一条搜索结果。
    func go(to result: SearchResult) {
        let chapter = engine.chapters[safe: result.chapterIndex]
        let locator = Locator(
            href: chapter?.filePath ?? "",
            locations: Locations(
                charOffset: result.charOffset,
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
        }

        persist(locator: locator, progression: engine.totalProgression, force: false)
    }

    private func persist(locator: Locator, progression: Double, force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(lastSavedAt) < saveInterval {
            return
        }
        lastSavedAt = now

        guard let data = try? JSONEncoder().encode(locator) else { return }

        if let progressEntity {
            progressEntity.locatorJSON = data
            progressEntity.totalProgression = progression
            progressEntity.updatedAt = now
        } else {
            let bookID = book.id
            let descriptor = FetchDescriptor<BookEntity>(
                predicate: #Predicate { $0.id == bookID }
            )
            guard let bookEntity = try? modelContext.fetch(descriptor).first else { return }

            let entity = ProgressEntity(
                locatorJSON: data,
                totalProgression: progression,
                updatedAt: now
            )
            entity.book = bookEntity
            modelContext.insert(entity)
            progressEntity = entity
        }

        try? modelContext.save()
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
        }
    }

    private func syncChapterState() {
        currentChapterIndex = engine.currentChapterIndex
        totalProgression = engine.totalProgression
    }
}
