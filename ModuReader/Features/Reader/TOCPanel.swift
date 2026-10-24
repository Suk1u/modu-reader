//
//  TOCPanel.swift
//  ModuReader
//
//  目录面板。三段式：章节 / 书签 / 高亮标记。
//
//  章节：左标题、右页码，当前章用圆角色块高亮。
//  书签：可多选删除。
//  下滑收起分段栏，上滑重新出现。
//
//  头部不用系统导航栏 —— 自绘才能保证顶栏与列表底色完全一致。
//

import SwiftUI
import UIKit

struct TOCPanel: View {

    let session: ReaderSession
    let bookTitle: String
    let pageText: String
    let onSelect: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var tab: Section = .chapters
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var headerCollapsed = false

    enum Section: String, CaseIterable, Identifiable {
        case chapters = "章节"
        case bookmarks = "书签"
        case highlights = "高亮标记"

        var id: String { rawValue }
    }

    private var chapters: [Chapter] { session.engine.chapters }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !headerCollapsed {
                segmentedPicker
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            content
        }
        .background(Color(uiColor: .systemBackground))
        .animation(.easeOut(duration: 0.2), value: headerCollapsed)
    }

    // MARK: - 头部

    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(bookTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(pageText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 60)

            HStack(spacing: 8) {
                ReaderCircleButton(systemName: "xmark", label: "关闭目录") {
                    dismiss()
                }

                Spacer(minLength: 0)

                if tab != .chapters {
                    trailingActions
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var trailingActions: some View {
        if isSelecting {
            Button {
                toggleSelectAll()
            } label: {
                Text(selection.count == currentSelectableIDs.count ? "取消全选" : "全选")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("全选")

            Button {
                deleteSelection()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
            .opacity(selection.isEmpty ? 0.35 : 1)
            .accessibilityLabel("删除所选")
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isSelecting = true
                    selection.removeAll()
                }
            } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择")
        }
    }

    private var segmentedPicker: some View {
        Picker("目录类型", selection: $tab) {
            ForEach(Section.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: tab) { _, _ in
            isSelecting = false
            selection.removeAll()
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .chapters:
            chapterList
        case .bookmarks:
            bookmarkList
        case .highlights:
            ContentUnavailableView {
                Label("没有高亮标记", systemImage: "highlighter")
            } description: {
                Text("选中正文后可以添加高亮。")
            }
        }
    }

    private var chapterList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(chapters) { chapter in
                    Button {
                        session.goToChapterWithHistory(chapter.id)
                        onSelect()
                        dismiss()
                    } label: {
                        chapterRow(chapter)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(chapter.title)
                    .accessibilityValue(
                        chapter.id == session.currentChapterIndex ? "当前章节" : ""
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .trackHeaderCollapse($headerCollapsed)
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        let isCurrent = chapter.id == session.currentChapterIndex

        return HStack(spacing: 12) {
            Text(chapter.title)
                .font(.system(size: 16, weight: chapter.isGroup ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.leading, CGFloat(chapter.level) * 14)

            Spacer(minLength: 8)

            if let page = session.pageNumber(forChapter: chapter.id) {
                Text("\(page)")
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
                .padding(.leading, 14)
        }
        .contentShape(.rect)
    }

    private var bookmarkList: some View {
        Group {
            if session.bookmarks.isEmpty {
                ContentUnavailableView {
                    Label("没有书签", systemImage: "bookmark")
                } description: {
                    Text("在阅读页点右上角的书签按钮即可添加。")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.bookmarks) { bookmark in
                            Button {
                                handleBookmarkTap(bookmark)
                            } label: {
                                bookmarkRow(bookmark)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .trackHeaderCollapse($headerCollapsed)
            }
        }
    }

    private func bookmarkRow(_ bookmark: BookmarkItem) -> some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: selection.contains(bookmark.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selection.contains(bookmark.id) ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.chapterTitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(dayText(bookmark.createdAt))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("\(session.pageNumber(atProgression: bookmark.progression))")
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
                .padding(.leading, 14)
        }
        .contentShape(.rect)
        .accessibilityLabel(bookmark.chapterTitle)
    }

    private func handleBookmarkTap(_ bookmark: BookmarkItem) {
        if isSelecting {
            if selection.contains(bookmark.id) {
                selection.remove(bookmark.id)
            } else {
                selection.insert(bookmark.id)
            }
            return
        }

        session.seekWithHistory(toProgression: bookmark.progression)
        onSelect()
        dismiss()
    }

    // MARK: - 选择

    private var currentSelectableIDs: Set<UUID> {
        Set(session.bookmarks.map(\.id))
    }

    private func toggleSelectAll() {
        if selection.count == currentSelectableIDs.count {
            selection.removeAll()
        } else {
            selection = currentSelectableIDs
        }
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        session.deleteBookmarks(selection)
        withAnimation(.easeOut(duration: 0.18)) {
            selection.removeAll()
            if session.bookmarks.isEmpty {
                isSelecting = false
            }
        }
    }

    private func dayText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - 下滑收起头部

private extension View {
    /// 向下滚动收起分段栏，向上滚动恢复。
    func trackHeaderCollapse(_ collapsed: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { oldValue, newValue in
            let delta = newValue - oldValue
            if delta > 4, newValue > 24, !collapsed.wrappedValue {
                collapsed.wrappedValue = true
            } else if delta < -4, collapsed.wrappedValue {
                collapsed.wrappedValue = false
            }
        }
    }
}