//
//  ReaderChrome.swift
//  ModuReader
//
//  阅读器功能层：顶部悬浮栏、底部悬浮栏、快捷菜单与右侧快速定位条。
//
//  Liquid Glass 只出现在这里。正文画布不加任何玻璃效果。
//
//  尺寸取自 iOS 26 Apple Books 实测规范：
//  - 圆形按钮 44×44（玻璃圆 44pt，图标 16pt）
//  - 状态胶囊高 28pt、字号 12pt；页码胶囊高 29pt、字号 12.5pt
//  - 顶栏距顶 0（贴着安全区），底栏距底 1pt
//  - 快速定位条常态 7.5×33%，拖拽态 18×46%
//

import SwiftUI

// MARK: - 玻璃圆形按钮

/// 44pt 玻璃圆形图标按钮。功能层的最小触控热区。
struct GlassIconButton: View {

    let title: String
    let systemImage: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - 顶部悬浮栏

struct ReaderTopBar: View {

    /// 中间胶囊的文字。
    let statusText: String
    let isBookmarked: Bool
    let onClose: () -> Void
    let onToggleBookmark: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            GlassIconButton(
                title: "关闭阅读器",
                systemImage: "xmark",
                action: onClose
            )

            Spacer(minLength: 0)

            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
                .contentTransition(.opacity)
                .accessibilityLabel("阅读状态")
                .accessibilityValue(statusText)

            Spacer(minLength: 0)

            GlassIconButton(
                title: isBookmarked ? "移除书签" : "添加书签",
                systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                tint: isBookmarked ? .red : .primary,
                action: onToggleBookmark
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, 18)
    }
}

// MARK: - 底部悬浮栏

struct ReaderBottomBar: View {

    /// 页码胶囊文字，例如 `18/255页`。
    let pageText: String
    let canReturn: Bool
    let onReturn: () -> Void
    let onOpenMenu: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if canReturn {
                GlassIconButton(
                    title: "回到跳转前的位置",
                    systemImage: "arrow.uturn.backward",
                    action: onReturn
                )
                .transition(.scale.combined(with: .opacity))
            }

            Spacer(minLength: 0)

            Text(pageText)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
                .contentTransition(.numericText())
                .accessibilityLabel("页码")
                .accessibilityValue(pageText)

            Spacer(minLength: 0)

            GlassIconButton(
                title: "更多",
                systemImage: "ellipsis",
                action: onOpenMenu
            )
        }
        .padding(.leading, 29)
        .padding(.trailing, 30)
        .padding(.bottom, 1)
    }
}

// MARK: - 快捷菜单

/// 底栏「更多」上方弹出的玻璃菜单。
struct ReaderQuickMenu: View {

    let onOpenTOC: () -> Void
    let onOpenSearch: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row("目录", systemImage: "list.bullet.rectangle", action: onOpenTOC)
            divider
            row("在图书中搜索", systemImage: "magnifyingglass", action: onOpenSearch)
            divider
            row("主题与设置", systemImage: "textformat.size", action: onOpenSettings)
        }
        .padding(.vertical, 4)
        .frame(width: 250)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 20)
            .accessibilityHidden(true)
    }

    private func row(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 28, alignment: .center)
                Text(title)
                    .font(.system(size: 16))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(height: 48.5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - 右侧快速定位条

/// 右侧边缘的纵向快速定位条。
///
/// 常态是细轨道；拖动时整体放大、外移，并在滑块左侧浮出
/// 双行气泡（章节名 + 目标页码），松手才真正跳转。
struct ReaderScrubber: View {

    @Bindable var session: ReaderSession
    /// 只有工具栏可见时才响应，避免挡住正文的翻页 / 滚动手势。
    let isActive: Bool

    @State private var dragValue: Double?

    private let normalWidth: CGFloat = 7.5
    private let activeWidth: CGFloat = 18
    private let normalHeightRatio: CGFloat = 0.33
    private let activeHeightRatio: CGFloat = 0.46

    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            let isDragging = dragValue != nil
            let trackWidth = isDragging ? activeWidth : normalWidth
            let trackHeight = height * (isDragging ? activeHeightRatio : normalHeightRatio)
            let trackTop = (height - trackHeight) / 2
            let trailing = isDragging ? CGFloat(18) : CGFloat(12)
            let progress = dragValue ?? session.totalProgression
            let thumbY = trackTop + trackHeight * progress

            ZStack(alignment: .trailing) {
                if isActive || isDragging {
                    Capsule()
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: trackWidth, height: trackHeight)
                        .padding(.trailing, trailing)

                    Capsule()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: trackWidth, height: max(44, trackHeight * progress))
                        .frame(height: trackHeight, alignment: .top)
                        .padding(.trailing, trailing)
                }

                if isDragging {
                    callout(for: progress)
                        .padding(.trailing, trailing + trackWidth + 2)
                        .offset(y: clampedY(thumbY, height: height))
                        .allowsHitTesting(false)
                }

                if isActive {
                    Color.clear
                        .frame(width: 44)
                        .contentShape(.rect)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { gesture in
                                    let fraction = (gesture.location.y - trackTop) / trackHeight
                                    dragValue = min(max(fraction, 0), 1)
                                }
                                .onEnded { _ in
                                    if let value = dragValue {
                                        session.seekWithHistory(toProgression: value)
                                    }
                                    dragValue = nil
                                }
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .animation(.snappy(duration: 0.22), value: isDragging)
        }
        .accessibilityHidden(true)
    }

    private func callout(for progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.chapterTitle(atProgression: progress))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(pageLabel(for: progress))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 267, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func pageLabel(for progress: Double) -> String {
        let total = session.totalPageCount
        guard total > 0 else {
            return "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
        }
        let page = Int((progress * Double(total)).rounded())
        return "第 \(min(max(page, 1), total)) 页"
    }

    /// 气泡不能贴到屏幕外。
    private func clampedY(_ y: CGFloat, height: CGFloat) -> CGFloat {
        let margin: CGFloat = 56
        let clamped = min(max(y, margin), height - margin)
        return clamped - height / 2
    }
}