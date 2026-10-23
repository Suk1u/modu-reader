//
//  TOCPanel.swift
//  ModuReader
//
//  目录面板。大目录用 List 懒加载，禁止一次性构建所有行。
//
//  目录保留原书的层级（卷 → 章 → 节）：子项按层级缩进，
//  带子项的分组节点加粗显示，不用序号占位。
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

    /// 非分组节点的顺序号。
    ///
    /// 分组节点（「第一卷」）不占正文，用它自己的章节序号会跳号，
    /// 所以只给真正的章节编号。
    private var displayNumbers: [Int: Int] {
        var result: [Int: Int] = [:]
        var counter = 0
        for chapter in chapters where !chapter.isGroup {
            counter += 1
            result[chapter.id] = counter
        }
        return result
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
                        row(for: chapter)
                    }
                    .accessibilityLabel(chapter.title)
                    .accessibilityValue(accessibilityValue(for: chapter))
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

    private func row(for chapter: Chapter) -> some View {
        HStack(spacing: 10) {
            Text(numberText(for: chapter))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)

            Text(chapter.title)
                .font(chapter.isGroup ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(
                    chapter.id == session.currentChapterIndex
                        ? .primary
                        : (chapter.isGroup ? .primary : .secondary)
                )
                .lineLimit(2)

            Spacer(minLength: 0)

            if chapter.id == session.currentChapterIndex {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(ReaderTheme.paper.accentColor)
                    .accessibilityHidden(true)
            }
        }
        // 搜索时结果是扁平的，缩进反而看不懂
        .padding(.leading, searchText.isEmpty ? CGFloat(chapter.level) * 16 : 0)
        .padding(.vertical, chapter.isGroup ? 4 : 2)
        .contentShape(.rect)
    }

    private func numberText(for chapter: Chapter) -> String {
        guard let number = displayNumbers[chapter.id] else { return "" }
        return "\(number)"
    }

    private func accessibilityValue(for chapter: Chapter) -> String {
        var parts: [String] = []
        if chapter.isGroup {
            parts.append("分组")
        }
        if chapter.level > 0 {
            parts.append("第 \(chapter.level + 1) 级")
        }
        if chapter.id == session.currentChapterIndex {
            parts.append("当前章节")
        }
        return parts.joined(separator: "，")
    }
}