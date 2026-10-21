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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isImporting = true
                        } label: {
                            Label("导入书籍", systemImage: "plus")
                        }
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .accessibilityLabel("添加书籍")
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
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
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
            Task {
                await importFiles(urls)
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func importFiles(_ urls: [URL]) async {
        let service = appContainer.makeImportService(context: modelContext)
        var failures: [String] = []

        for url in urls {
            do {
                _ = try await service.importFile(at: url)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        importingCount = 0
        if !failures.isEmpty {
            importError = failures.joined(separator: "\n")
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
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
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
