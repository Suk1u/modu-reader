//
//  ReaderChrome.swift
//  ModuReader
//
//  阅读器功能层：顶部工具栏与底部进度条。
//
//  Liquid Glass 只出现在这里。正文画布不加任何玻璃效果。
//

import SwiftUI

/// 顶部工具栏。
struct ReaderTopBar: View {

    let title: String
    let onBack: () -> Void
    let onOpenTOC: () -> Void
    let onOpenSearch: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onBack) {
                Label("返回", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("返回书架")

            Button(action: onOpenTOC) {
                Label("目录", systemImage: "list.bullet")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("目录")

            Button(action: onOpenSearch) {
                Label("搜索", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("搜索全书")

            Spacer(minLength: 8)

            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// 底部工具条：进度条 + 章节导航 + 设置入口。
struct ReaderBottomBar: View {

    @Bindable var session: ReaderSession
    let onOpenSettings: () -> Void

    /// 拖动进度条时的临时值。拖动结束才提交，避免频繁 seek。
    @State private var scrubbingValue: Double?
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 10) {
            progressRow

            HStack(spacing: 0) {
                Button {
                    session.previousChapter()
                } label: {
                    Label("上一章", systemImage: "backward.end")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .disabled(session.currentChapterIndex == 0)
                .accessibilityLabel("上一章")

                Spacer(minLength: 0)

                Text(chapterLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("当前章节")
                    .accessibilityValue(chapterLabel)

                Spacer(minLength: 0)

                Button {
                    session.nextChapter()
                } label: {
                    Label("下一章", systemImage: "forward.end")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .disabled(session.currentChapterIndex >= session.chapterCount - 1)
                .accessibilityLabel("下一章")

                Button(action: onOpenSettings) {
                    Label("阅读设置", systemImage: "textformat.size")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("阅读设置")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var progressRow: some View {
        HStack(spacing: 10) {
            Text(percentLabel(for: scrubbingValue ?? session.totalProgression))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            Slider(
                value: Binding(
                    get: { scrubbingValue ?? session.totalProgression },
                    set: { newValue in
                        scrubbingValue = newValue
                        if !isScrubbing {
                            isScrubbing = true
                        }
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing {
                        isScrubbing = false
                        if let value = scrubbingValue {
                            session.seek(toProgression: value)
                        }
                        scrubbingValue = nil
                    }
                }
            )
            .accessibilityLabel("阅读进度")
            .accessibilityValue(percentLabel(for: session.totalProgression))

            Text(percentLabel(for: 1.0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var chapterLabel: String {
        let index = session.currentChapterIndex + 1
        let total = max(1, session.chapterCount)
        return "\(index) / \(total) · \(session.currentChapterTitle)"
    }

    private func percentLabel(for value: Double) -> String {
        let clamped = max(0, min(1, value))
        return "\(Int((clamped * 100).rounded()))%"
    }
}
