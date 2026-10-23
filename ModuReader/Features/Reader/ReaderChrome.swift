//
//  ReaderChrome.swift
//  ModuReader
//
//  阅读器功能层：顶部悬浮栏、底部悬浮栏、快捷菜单与右侧快速定位条。
//
//  Liquid Glass 只出现在这里。正文画布不加任何玻璃效果。
//
//  ── 布局来源 ──
//
//  顶栏：左圆形关闭 / 中间状态胶囊 / 右圆形书签
//  底栏：左回跳（有跳转历史时才出现）/ 中间页码胶囊 / 右更多菜单
//  目录、搜索、设置都收进「更多」菜单，顶栏不再堆按钮。
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
                // 视觉 40pt，触控热区 44pt
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: Circle())
                .frame(width: 44, height: 44)
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
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
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
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
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
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
            row("目录", systemImage: "list.bullet.rectangle.portrait", action: onOpenTOC)
            row("在图书中搜索", systemImage: "magnifyingglass", action: onOpenSearch)
            row("主题与设置", systemImage: "textformat.size", action: onOpenSettings)
        }
        .padding(6)
        .frame(width: 232)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - 右侧快速定位条

/// 右侧边缘的纵向快速定位条。
///
/// 拖动时在滑块左侧浮出双行气泡（章节名 + 目标页码），松手才真正跳转，
/// 跳转前的位置会进入回跳历史。
struct ReaderScrubber: View {

    @Bindable var session: ReaderSession
    /// 只有工具栏可见时才响应，避免挡住正文的翻页 / 滚动手势。
    let isActive: Bool

    @State private var dragValue: Double?

    private let trackWidth: CGFloat = 4
    private let trackHeightRatio: CGFloat = 0.62

    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            let trackHeight = height * trackHeightRatio
            let trackTop = (height - trackHeight) / 2
            let progress = dragValue ?? session.totalProgression
            let thumbY = trackTop + trackHeight * progress

            ZStack(alignment: .trailing) {
                if isActive || dragValue != nil {
                    Capsule()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: trackWidth, height: trackHeight)
                        .padding(.trailing, 6)

                    Capsule()
                        .fill(ReaderTheme.paper.accentColor)
                        .frame(width: trackWidth, height: 44)
                        .padding(.trailing, 6)
                        .offset(y: thumbY - height / 2)
                }

                if dragValue != nil {
                    callout(for: progress)
                        .padding(.trailing, 22)
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
        }
        .accessibilityHidden(true)
    }

    private func callout(for progress: Double) -> some View {
        VStack(spacing: 2) {
            Text(session.chapterTitle(atProgression: progress))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(pageLabel(for: progress))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 210)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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