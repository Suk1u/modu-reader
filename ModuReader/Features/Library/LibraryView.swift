//
//  LibraryView.swift
//  ModuReader
//
//  书架。NavigationStack + 自适应网格 + 空状态。
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {

    @Environment(AppContainer.self) private var appContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookEntity.lastOpenedAt, order: .reverse) private var books: [BookEntity]

    @State private var isImporting = false
    @State private var importError: String?
    @State private var importSuccessMessage: String?
    @State private var importingCount = 0
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .recent
    @State private var openedBook: BookEntity?
    @State private var bookToDelete: BookEntity?

    private var filteredBooks: [BookEntity] {
        let base: [BookEntity]
        if searchText.isEmpty {
            base = books
        } else {
            base = books.filter { book in
                book.title.localizedStandardContains(searchText)
                    || (book.author?.localizedStandardContains(searchText) ?? false)
            }
        }
        return sortOrder.sort(base)
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    emptyState
                } else if filteredBooks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    bookGrid
                }
            }
            .navigationTitle("书架")
            .searchable(text: $searchText, prompt: "搜索书名或作者")
            .toolbar {
                // 直接按钮，不套 Menu。
                // 菜单项点击后菜单需要先 dismiss，再呈现 sheet，
                // 两者竞争会导致 fileImporter 偶尔完全不出现（表现为「点导入没反应」）。
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentImporter()
                    } label: {
                        Label("导入书籍", systemImage: "plus")
                    }
                    .accessibilityLabel("导入书籍")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $sortOrder) {
                            ForEach(LibrarySortOrder.allCases) { order in
                                Text(order.displayName).tag(order)
                            }
                        }
                    } label: {
                        Label("排序", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("排序方式")
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: FormatSniffer.supportedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .fullScreenCover(item: $openedBook) { book in
                ReaderView(book: book.descriptor)
            }
            // 从 Files App、分享面板、「用其他应用打开」进入时，
            // 系统通过 openURL 把文件交给本 App（Info.plist 已声明 CFBundleDocumentTypes）。
            .onOpenURL { url in
                Task {
                    await importFromOpenURL(url)
                }
            }
            .overlay(alignment: .top) {
                if importingCount > 0 {
                    importingBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .confirmationDialog(
                "删除《\(bookToDelete?.title ?? "")》？",
                isPresented: Binding(
                    get: { bookToDelete != nil },
                    set: { if !$0 { bookToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let book = bookToDelete {
                        delete(book)
                    }
                    bookToDelete = nil
                }
                Button("取消", role: .cancel) {
                    bookToDelete = nil
                }
            } message: {
                Text("将同时删除阅读进度。此操作不可撤销。")
            }
        }
        // 注意：alert 必须挂在 NavigationStack 外层。
        // 挂在内部时，fileImporter 的 sheet 刚 dismiss 就弹 alert，
        // iOS 26 会丢弃这次呈现，用户完全看不到失败原因。
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert("导入成功", isPresented: Binding(
            get: { importSuccessMessage != nil },
            set: { if !$0 { importSuccessMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importSuccessMessage ?? "")
        }
    }

    /// 导入进度条。
    ///
    /// 刻意做成不阻挡交互的顶部横幅，而不是全屏遮罩：
    /// 全屏遮罩一旦因异常未关闭，用户会以为整个 App 卡死。
    private var importingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(importingCount == 1 ? "正在导入…" : "正在导入 \(importingCount) 个文件…")
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView {
            Label("书架空空如也", systemImage: "books.vertical")
        } description: {
            Text("导入 TXT 或 Markdown 文件开始阅读。")
        } actions: {
            Button("导入书籍") {
                isImporting = true
            }
            .buttonStyle(.glassProminent)
        }
    }

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 16)],
                spacing: 20
            ) {
                ForEach(filteredBooks) { book in
                    BookCard(book: book)
                        .onTapGesture {
                            open(book)
                        }
                        .contextMenu {
                            Button {
                                open(book)
                            } label: {
                                Label("打开", systemImage: "book")
                            }
                            Button(role: .destructive) {
                                bookToDelete = book
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    // MARK: - Actions

    /// 呈现文件选择器。
    ///
    /// 延迟一拍再置位 `isImporting`：如果当前有菜单/弹出层正在关闭，
    /// 立即呈现 sheet 会被系统丢弃。
    private func presentImporter() {
        DispatchQueue.main.async {
            isImporting = true
        }
    }

    private func open(_ book: BookEntity) {
        book.lastOpenedAt = Date()
        try? modelContext.save()
        openedBook = book
    }

    private func delete(_ book: BookEntity) {
        let service = appContainer.makeImportService(context: modelContext)
        try? service.deleteBook(book)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            importingCount = urls.count

            // 关键：在回调内**同步**复制到沙盒临时目录。
            //
            // fileImporter 的 completion 在 sheet dismiss 之后才执行，
            // 此时 security scope 可能已经失效。若在异步任务里再去读原 URL，
            // 会得到「文件不存在 / 无权限」，而错误又被 SwiftUI 丢弃，
            // 表现就是「点了打开没反应」。
            //
            // 同步复制虽然会占用主线程一小段时间，但这是唯一可靠的方式。
            // 单个文件复制 5MB 约 10~30ms，可以接受。
            var staged: [(url: URL, originalName: String)] = []
            var stagingFailures: [String] = []

            for url in urls {
                let originalName = url.lastPathComponent
                do {
                    let temp = try StageFile.copyToStaging(url)
                    staged.append((temp, originalName))
                } catch {
                    stagingFailures.append("\(originalName)：\(error.localizedDescription)")
                }
            }

            if staged.isEmpty {
                importingCount = 0
                importError = stagingFailures.isEmpty
                    ? "未能读取所选文件。"
                    : stagingFailures.joined(separator: "\n")
                return
            }

            Task {
                await importFiles(staged, stagingFailures: stagingFailures)
                importingCount = 0
            }
        case .failure(let error):
            // 用户主动取消不算错误，不弹窗
            let nsError = error as NSError
            if nsError.code == NSUserCancelledError { return }
            importError = error.localizedDescription
        }
    }

    /// 处理系统通过 openURL 传入的文件。
    ///
    /// 同样先同步暂存：openURL 给的 URL 可能是 Inbox 临时副本，
    /// 系统会在回调返回后清理。
    private func importFromOpenURL(_ url: URL) async {
        let originalName = url.lastPathComponent
        let staged: URL
        do {
            staged = try StageFile.copyToStaging(url)
        } catch {
            importError = "\(originalName)：\(error.localizedDescription)"
            return
        }

        importingCount = 1
        defer { importingCount = 0 }

        let service = appContainer.makeImportService(context: modelContext)
        do {
            let result = try await service.importFile(
                at: staged,
                originalFileName: originalName
            )
            importSuccessMessage = "已添加《\(result.title)》。"
        } catch {
            importError = "\(originalName)：\(error.localizedDescription)"
        }
        StageFile.discard(staged)
    }

    /// 导入暂存文件。
    ///
    /// - Parameters:
    ///   - staged: 暂存副本 URL 与原始文件名。
    ///   - stagingFailures: 暂存阶段就已失败的文件说明。
    private func importFiles(
        _ staged: [(url: URL, originalName: String)],
        stagingFailures: [String]
    ) async {
        let service = appContainer.makeImportService(context: modelContext)
        var failures = stagingFailures
        var imported = 0

        for item in staged {
            defer { StageFile.discard(item.url) }

            do {
                _ = try await service.importFile(
                    at: item.url,
                    originalFileName: item.originalName
                )
                imported += 1
            } catch {
                failures.append("\(item.originalName)：\(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            importError = failures.joined(separator: "\n")
        } else if imported > 0 {
            importSuccessMessage = imported == 1
                ? "已添加 1 本书。"
                : "已添加 \(imported) 本书。"
        }
    }
}

// MARK: - Sort

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case recent
    case added
    case title

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recent: "最近阅读"
        case .added: "添加时间"
        case .title: "书名"
        }
    }

    func sort(_ books: [BookEntity]) -> [BookEntity] {
        switch self {
        case .recent:
            books.sorted {
                ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
            }
        case .added:
            books.sorted { $0.addedAt > $1.addedAt }
        case .title:
            books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

// MARK: - BookCard

struct BookCard: View {
    let book: BookEntity

    private var progress: Double {
        book.progress?.totalProgression ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover

            Text(book.title)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)

            if let author = book.author, !author.isEmpty {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if progress > 0.001 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(ReaderTheme.paper.accentColor)
                    .accessibilityLabel("阅读进度")
                    .accessibilityValue("\(Int(progress * 100))%")
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var cover: some View {
        ZStack {
            ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
                .fill(coverGradient)

            VStack(spacing: 6) {
                Image(systemName: "text.book.closed.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                Text(book.title)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .overlay {
            ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }

    private var coverGradient: LinearGradient {
        let seed = abs(book.title.hashValue)
        let hue = Double(seed % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.35, brightness: 0.62),
                Color(hue: hue, saturation: 0.45, brightness: 0.42),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var accessibilityDescription: String {
        var parts = [book.title]
        if let author = book.author, !author.isEmpty {
            parts.append(author)
        }
        if progress > 0.001 {
            parts.append("已读 \(Int(progress * 100))%")
        } else {
            parts.append("未读")
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - Preview

#Preview("书架") {
    let container = try! ModuModelContainer.makeInMemory()
    return LibraryView()
        .environment(AppContainer(modelContainer: container))
        .modelContainer(container)
}
