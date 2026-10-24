//
//  ReaderChrome.swift
//  ModuReader
//
//  阅读器功能层：顶部悬浮栏、底部悬浮栏与右侧快速定位条。
//
//  Liquid Glass 只出现在这里。正文画布不加任何玻璃效果。
//
//  圆形按钮统一使用 `ReaderCircleButton`：50pt 玻璃圆、29pt 呼吸区、
//  按下轻微凹陷、轻触反馈。底部「更多」用原生 `Menu`，
//  label 保持裸 Image，由系统负责菜单材质与无障碍。
//

import SwiftUI

// MARK: - 圆形玻璃按钮

struct ReaderCircleButton: View {
    let systemName: String
    var tint: Color = .primary
    var disabled: Bool = false
    var label: String? = nil
    let action: () -> Void

    // MARK: 设计常量
    private let size: CGFloat = 50
    private let iconSize: CGFloat = 29
    private let radius: CGFloat = 25

    @State private var tapCount = 0

    var body: some View {
        Button {
            guard !disabled else { return }
            tapCount += 1
            withAnimation(.easeOut(duration: 0.18)) { action() }
        } label: {
            Image(systemName: systemName)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: iconSize, height: iconSize)
                .frame(width: size, height: size)
                .contentShape(.circle)
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: radius, style: .continuous)
                )
                .glassEffectTransition(.materialize)
                .opacity(disabled ? 0.38 : 1)
        }
        .buttonStyle(ReaderCircleButtonStyle())
        .disabled(disabled)
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
        .accessibilityLabel(label ?? systemName)
    }
}

/// 按下轻微凹陷；0.94 与 50pt 体量匹配。
struct ReaderCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 与 `ReaderCircleButton` 同款外观的菜单按钮。
///
/// label 保持裸 Image —— 玻璃、按压与命中区都在 label 上完成，
/// 菜单内容交给系统渲染。
struct ReaderCircleMenu<Content: View>: View {

    let systemName: String
    var tint: Color = .primary
    var label: String? = nil
    @ViewBuilder var content: () -> Content

    private let size: CGFloat = 50
    private let iconSize: CGFloat = 29
    private let radius: CGFloat = 25

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemName)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: iconSize, height: iconSize)
                .frame(width: size, height: size)
                .contentShape(.circle)
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: radius, style: .continuous)
                )
                .glassEffectTransition(.materialize)
        }
        .accessibilityLabel(label ?? systemName)
    }
}

// MARK: - 顶部悬浮栏

struct ReaderTopBar: View {

    /// 中间胶囊的文字。
    let statusText: String
    /// 按钮图标颜色，跟随阅读主题。
    let tint: Color
    let isBookmarked: Bool
    let onClose: () -> Void
    let onToggleBookmark: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ReaderCircleButton(
                systemName: "xmark",
                tint: tint,
                label: "关闭阅读器",
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

            ReaderCircleButton(
                systemName: isBookmarked ? "bookmark.fill" : "bookmark",
                tint: isBookmarked ? .red : tint,
                label: isBookmarked ? "移除书签" : "添加书签",
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
    let tint: Color
    let canReturn: Bool
    let onReturn: () -> Void
    let onOpenTOC: () -> Void
    let onOpenSearch: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        // 用 ZStack 而不是 Spacer 布局：页码必须相对屏幕居中，
        // 不能因为左侧回跳按钮时有时无而左右偏移。
        ZStack {
            Text(pageText)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.28), value: pageText)
                .accessibilityLabel("页码")
                .accessibilityValue(pageText)

            HStack(spacing: 12) {
                if canReturn {
                    ReaderCircleButton(
                        systemName: "arrow.uturn.backward",
                        tint: tint,
                        label: "回到跳转前的位置",
                        action: onReturn
                    )
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Color.clear
                        .frame(width: 50, height: 50)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)

                ReaderCircleMenu(
                    systemName: "ellipsis",
                    tint: tint,
                    label: "更多"
                ) {
                    Button {
                        onOpenTOC()
                    } label: {
                        Label("目录", systemImage: "list.bullet.rectangle")
                    }

                    Button {
                        onOpenSearch()
                    } label: {
                        Label("在图书中搜索", systemImage: "magnifyingglass")
                    }

                    Button {
                        onOpenSettings()
                    } label: {
                        Label("主题与设置", systemImage: "textformat.size")
                    }
                }
            }
        }
        .padding(.leading, 29)
        .padding(.trailing, 30)
        .padding(.bottom, 1)
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
                    // 轨道与进度放在同一个容器里，缩放时一起动画，
                    // 分开写会各自补间，放大过程中出现短暂错位。
                    ZStack(alignment: .top) {
                        Capsule()
                            .fill(Color.primary.opacity(0.22))
                        Capsule()
                            .fill(Color.primary.opacity(0.55))
                            .frame(height: max(44, trackHeight * progress))
                    }
                    .frame(width: trackWidth, height: trackHeight)
                    .padding(.trailing, trailing)
                }

                if isDragging {
                    let bubbleCenter = clampedBubbleCenter(thumbY, height: height)
                    callout(for: progress, tailOffset: thumbY - bubbleCenter)
                        .padding(.trailing, trailing + trackWidth + 2)
                        .offset(y: bubbleCenter - height / 2)
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
            .animation(
                .spring(response: 0.5, dampingFraction: 0.78, blendDuration: 0.15),
                value: isDragging
            )
        }
        .sensoryFeedback(.impact(weight: .light), trigger: dragValue == nil)
        .accessibilityHidden(true)
    }

    /// 章节气泡。
    ///
    /// 用带指向箭头的自定义 `Shape` 交给 `glassEffect` 渲染 ——
    /// 箭头也是玻璃材质的一部分，不是叠上去的图形。
    /// `tailOffset` 让箭头始终对准滑块，气泡被挤到屏幕边缘时箭头会相应偏移。
    private func callout(for progress: Double, tailOffset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.chapterTitle(atProgression: progress))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(pageLabel(for: progress))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 18)
        .padding(.trailing, 18 + ScrubberBubbleShape.tailWidth)
        .padding(.vertical, 14)
        .frame(maxWidth: 267, alignment: .leading)
        .glassEffect(
            .regular,
            in: ScrubberBubbleShape(tailOffsetFromCenter: tailOffset)
        )
    }

    private func pageLabel(for progress: Double) -> String {
        let total = session.totalPageCount
        guard total > 0 else {
            return "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
        }
        let page = Int((progress * Double(total)).rounded())
        return "第 \(min(max(page, 1), total)) 页"
    }

    /// 气泡中心不能贴到屏幕外。
    private func clampedBubbleCenter(_ y: CGFloat, height: CGFloat) -> CGFloat {
        let margin: CGFloat = 56
        return min(max(y, margin), height - margin)
    }
}

// MARK: - 带指向箭头的气泡形状

/// 右侧带一个指向滑块的小三角的气泡。
///
/// 三角与圆角矩形成**单个轮廓**（`union`），这样液态玻璃的
/// 高光描边会沿着整体轮廓走，不会在接缝处出现一条亮线。
struct ScrubberBubbleShape: Shape {

    static let tailWidth: CGFloat = 9
    static let tailHeight: CGFloat = 15

    /// 箭头中心相对气泡中心的偏移。0 表示正对中心。
    var tailOffsetFromCenter: CGFloat = 0
    var cornerRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let bodyWidth = max(1, rect.width - Self.tailWidth)

        var body = Path(
            roundedRect: CGRect(
                x: rect.minX,
                y: rect.minY,
                width: bodyWidth,
                height: rect.height
            ),
            cornerRadius: cornerRadius,
            style: .continuous
        )

        // 箭头不能超出圆角区域，否则轮廓会自交
        let limit = cornerRadius + Self.tailHeight / 2
        let centerY = min(
            max(rect.midY + tailOffsetFromCenter, rect.minY + limit),
            rect.maxY - limit
        )

        var tail = Path()
        tail.move(to: CGPoint(x: rect.minX + bodyWidth, y: centerY - Self.tailHeight / 2))
        tail.addLine(to: CGPoint(x: rect.maxX, y: centerY))
        tail.addLine(to: CGPoint(x: rect.minX + bodyWidth, y: centerY + Self.tailHeight / 2))
        tail.closeSubpath()

        return body.union(tail)
    }
}