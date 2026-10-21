//
//  SearchPanel.swift
//  ModuReader
//
//  全书搜索面板。后台逐章扫描，结果可点击跳转。
//

import SwiftUI

struct SearchPanel: View {

    let session: ReaderSession
    let onSelect: (SearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView("正在搜索…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasSearched {
                    ContentUnavailableView {
                        Label("搜索全书", systemImage: "magnifyingglass")
                    } description: {
                        Text("输入关键词，在全部章节中查找。")
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    resultList
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索全书"
            )
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .onDisappear {
                searchTask?.cancel()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var resultList: some View {
        List {
            Section {
                ForEach(results) { result in
                    Button {
                        onSelect(result)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.chapterTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(highlighted(result.context, query: query))
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(result.chapterTitle)：\(result.context)")
                }
            } header: {
                Text("\(results.count) 个结果")
            }
        }
        .listStyle(.plain)
    }

    /// 用 AttributedString 高亮关键词。
    private func highlighted(_ context: String, query: String) -> AttributedString {
        var attributed = AttributedString(context)
        guard !query.isEmpty else { return attributed }

        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(
            of: query,
            options: [.caseInsensitive]
        ) {
            attributed[range].backgroundColor = .yellow.opacity(0.35)
            attributed[range].font = .subheadline.bold()
            searchStart = range.upperBound
            if searchStart >= attributed.endIndex { break }
        }
        return attributed
    }

    /// 防抖：输入停止 350ms 后才发起搜索，避免每个字符都扫全书。
    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            isSearching = true
            let found = await session.search(trimmed)
            guard !Task.isCancelled else { return }

            results = found
            isSearching = false
            hasSearched = true
        }
    }
}
