//
//  TOCPanel.swift
//  ModuReader
//
//  目录面板。大目录用 List 懒加载，禁止一次性构建所有行。
//

import SwiftUI

struct TOCPanel: View {

    let session: ReaderSession
    let onSelect: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var chapters: [Chapter] {
        session.engine.chapters
    }

    private var filteredChapters: [Chapter] {
        guard !searchText.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredChapters) { chapter in
                    Button {
                        session.goToChapter(chapter.id)
                        onSelect()
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(chapter.id + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, alignment: .trailing)

                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(chapter.id == session.currentChapterIndex ? .primary : .secondary)
                                .lineLimit(2)

                            Spacer(minLength: 0)

                            if chapter.id == session.currentChapterIndex {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2)
                                    .foregroundStyle(ReaderTheme.paper.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel(chapter.title)
                    .accessibilityValue(chapter.id == session.currentChapterIndex ? "当前章节" : "")
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索章节")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
