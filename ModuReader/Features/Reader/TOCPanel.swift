//
//  TOCPanel.swift
//  ModuReader
//
//  目录面板。三段式：章节 / 书签 / 高亮标记。
//
//  章节：左标题、右页码，当前章用圆角色块高亮。
//  书签 / 高亮：右上角进入选择模式，左上角变全选，右下角出现删除。
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

    /// 书签与高亮共用的行模型。
    private struct MarkRow: Identifiable {
        let id: UUID
        /// 主行：书签显示章节名，高亮显示被标记的文字。
        let title: String
        let date: Date
        let progression: Double
        let locator: Locator?
        /// 高亮跳转后把标记滚到屏幕中央。
        let centerOnJump: Bool
    }

    enum Section: String, CaseIterable, Identifiable {
        case chapters = "章节"
        case bookmarks = "书签"
        case highlights = "高亮标记"

        var id: String { rawValue }
    }

    private var chapters: [Chapter] { session.engine.chapters }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                header

                segmentedPicker
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                content
            }

            if isSelecting {
                ReaderCircleButton(
                    systemName: "trash",
                    tint: .red,
                    label: "删除所选"
                ) {
                    deleteSelection()
                }
                .opacity(selection.isEmpty ? 0.35 : 1)
                .disabled(selection.isEmpty)
                .padding(.trailing, 24)
                .padding(.bottom, 24)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .animation(.easeOut(duration: 0.18), value: isSelecting)
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
            .padding(.horizontal, 66)

            HStack(spacing: 8) {
                ReaderCircleButton(
                    systemName: isSelecting ? "checkmark.circle" : "xmark",
                    label: isSelecting ? "全选" : "关闭目录"
                ) {
                    if isSelecting {
                        toggleSelectAll()
                    } else {
                        dismiss()
                    }
                }

                Spacer(minLength: 0)

                if tab != .chapters {
                    ReaderCircleButton(
                        systemName: isSelecting ? "xmark" : "checklist",
                        label: isSelecting ? "取消选择" : "选择"
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isSelecting.toggle()
                            selection.removeAll()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
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
            markList(
                items: session.bookmarks.map {
                    MarkRow(
                        id: $0.id,
                        title: $0.chapterTitle,
                        date: $0.createdAt,
                        progression: $0.progression,
                        locator: $0.locator,
                        centerOnJump: false
                    )
                },
                emptyTitle: "没有书签",
                emptyMessage: "在阅读页点右上角的书签按钮即可添加。"
            )
        case .highlights:
            markList(
                items: session.highlights.map {
                    MarkRow(
                        id: $0.id,
                        title: $0.chapterTitle,
                        date: $0.createdAt,
                        progression: $0.progression,
                        locator: $0.locator,
                        centerOnJump: false
                    )
                },
                emptyTitle: "没有高亮标记",
                emptyMessage: "在阅读页的「更多」菜单里选择「高亮本页」。"
            )
        }
    }

    // MARK: - 章节

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

    // MARK: - 书签 / 高亮

    private func markList(
        items: [MarkRow],
        emptyTitle: String,
        emptyMessage: String
    ) -> some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: tab == .bookmarks ? "bookmark" : "highlighter")
                } description: {
                    Text(emptyMessage)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                handleMarkTap(item)
                            } label: {
                                markRow(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func markRow(_ item: MarkRow) -> some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(dayText(item.date))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("\(session.pageNumber(atProgression: item.progression))")
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
        .accessibilityLabel(item.title)
    }

    private func handleMarkTap(_ item: MarkRow) {
        if isSelecting {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
            return
        }

        session.goToMark(
            item.locator,
            fallbackProgression: item.progression,
            center: item.centerOnJump
        )
        onSelect()
        dismiss()
    }

    // MARK: - 选择

    private var currentSelectableIDs: Set<UUID> {
        switch tab {
        case .chapters:
            return []
        case .bookmarks:
            return Set(session.bookmarks.map(\.id))
        case .highlights:
            return Set(session.highlights.map(\.id))
        }
    }

    private func toggleSelectAll() {
        guard !currentSelectableIDs.isEmpty else { return }
        if selection.count == currentSelectableIDs.count {
            selection.removeAll()
        } else {
            selection = currentSelectableIDs
        }
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }

        switch tab {
        case .bookmarks:
            session.deleteBookmarks(selection)
        case .highlights:
            session.deleteHighlights(selection)
        case .chapters:
            break
        }

        withAnimation(.easeOut(duration: 0.18)) {
            selection.removeAll()
            if currentSelectableIDs.isEmpty {
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