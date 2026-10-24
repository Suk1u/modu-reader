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
import UIKit

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
    let onOpenTOC: () -> Void
    let onOpenSearch: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        // 页码相对整条底栏居中；回跳按钮已移到独立图层，
        // 沉浸阅读时也要能看到。
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

            // 基准尺寸不变，放大交给 scaleEffect ——
            // 轨道与内部进度共用同一个变换，缩放倍率、速率与曲线完全一致。
            let baseHeight = height * normalHeightRatio
            let scaleX = isDragging ? activeWidth / normalWidth : 1
            let scaleY = isDragging ? activeHeightRatio / normalHeightRatio : 1
            let visualWidth = normalWidth * scaleX
            let visualHeight = baseHeight * scaleY
            let visualTop = (height - visualHeight) / 2
            let visualTrailing: CGFloat = isDragging ? 18 : 12
            let progress = dragValue ?? session.totalProgression
            let thumbY = visualTop + visualHeight * progress

            // 放大后右缘要从 12pt 挪到 18pt，宽度也在变，换算成中心点位移
            let activeOffset = (CGFloat(12) - 18) + (normalWidth - activeWidth) / 2

            ZStack(alignment: .trailing) {
                if isActive || isDragging {
                    ZStack(alignment: .top) {
                        Capsule()
                            .fill(Color.primary.opacity(0.22))
                        Capsule()
                            .fill(Color.primary.opacity(0.55))
                            .frame(height: baseHeight * progress)
                    }
                    .frame(width: normalWidth, height: baseHeight)
                    .scaleEffect(x: scaleX, y: scaleY)
                    .padding(.trailing, 12)
                    .offset(x: isDragging ? activeOffset : 0)
                }

                if isDragging {
                    let bubbleCenter = clampedBubbleCenter(thumbY, height: height)
                    callout(for: progress, tailOffset: thumbY - bubbleCenter)
                        .padding(.trailing, visualTrailing + visualWidth + 2)
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
                                    let fraction = (gesture.location.y - visualTop) / visualHeight
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
        .frame(width: bubbleWidth(for: progress), alignment: .leading)
        .glassEffect(
            .regular,
            in: ScrubberBubbleShape(tailOffsetFromCenter: tailOffset)
        )
    }

    /// 按标题实际渲染宽度算气泡宽度，只有超过上限才截断。
    private func bubbleWidth(for progress: Double) -> CGFloat {
        let title = session.chapterTitle(atProgression: progress)
        let textWidth = (title as NSString).size(withAttributes: [.font: Self.titleFont]).width
        let chrome = 18 + 18 + ScrubberBubbleShape.tailWidth
        return min(ceil(textWidth) + chrome, Self.maxBubbleWidth)
    }

    private static let titleFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
    private static let maxBubbleWidth: CGFloat = 300

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
        let height = rect.height
        let bodyRight = rect.maxX - Self.tailWidth
        // 圆角不能超过半个宽高，否则窄气泡会画出畸形轮廓
        let radius = max(0, min(cornerRadius, height / 2, (bodyRight - rect.minX) / 2))
        let tailHalf = Self.tailHeight / 2

        // 箭头中心夹在两侧圆角之间，保证轮廓不自交
        let centerY = min(
            max(rect.midY + tailOffsetFromCenter, rect.minY + radius + tailHalf),
            rect.maxY - radius - tailHalf
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyRight - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: bodyRight - radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bodyRight, y: centerY - tailHalf))
        path.addLine(to: CGPoint(x: rect.maxX, y: centerY))
        path.addLine(to: CGPoint(x: bodyRight, y: centerY + tailHalf))
        path.addLine(to: CGPoint(x: bodyRight, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: bodyRight - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}