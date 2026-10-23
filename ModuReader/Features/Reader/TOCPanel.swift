//
//  TOCPanel.swift
//  ModuReader
//
//  目录面板。大目录用 List 懒加载，禁止一次性构建所有行。
//
//  列表排版保持不变；顶部改为「圆形关闭按钮 + 书名 + 当前页码」，
//  与阅读器其余面板的头部保持一致。
//
//  目录保留原书层级（卷 → 章 → 节）：子项按层级缩进，
//  带子项的分组节点加粗显示，不用序号占位。
//

import SwiftUI

struct TOCPanel: View {

    let session: ReaderSession
    /// 书名，作为面板主标题。
    let bookTitle: String
    /// 当前页码，作为副标题。
    let pageText: String
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
                        // 记下跳转前的位置，底栏会出现回跳按钮
                        session.goToChapterWithHistory(chapter.id)
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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索章节")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭目录")
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(bookTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Text(pageText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
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