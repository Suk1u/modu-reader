//
//  ReaderSettingsPanel.swift
//  ModuReader
//
//  「主题与设置」半屏面板。
//
//  尺寸取自 iOS 26 Apple Books 实测规范：
//  标题 18pt Bold、控制胶囊高 44pt、亮度轨道无外框、
//  主题卡片 86pt 高（圆角 18）、底部按钮高 47pt。
//
//  阅读方式与外观用原生 `Menu`：系统自带 Liquid Glass 菜单、勾选状态、
//  无障碍语义与键盘导航；按钮图标跟随当前选中项变化。
//

import SwiftUI
import UIKit

/// 外观选择。`system` 表示跟随设备明暗。
enum AppearanceChoice: Hashable {
    case light
    case dark
    case system
}

struct ReaderSettingsPanel: View {

    @Bindable var session: ReaderSession
    /// 阅读区亮度 0...1。只影响画布，不写进阅读设置。
    @Binding var brightness: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var showCustomTheme = false
    /// 调整字号后短暂显示刻度点。
    @State private var showFontDots = false
    @State private var dotHideTask: Task<Void, Never>?

    private static let minFontSize: Double = 12
    private static let maxFontSize: Double = 32
    private static let fontSteps = Int(maxFontSize - minFontSize)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 12)

                controlRow
                    .padding(.horizontal, 28)
                    .padding(.top, 11)

                brightnessRow
                    .padding(.horizontal, 28)
                    .padding(.top, 18)

                themeGrid
                    .padding(.horizontal, 28)
                    .padding(.top, 26)

                customThemeButton
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .sheet(isPresented: $showCustomTheme) {
            CustomThemePanel(session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }

    // MARK: - 标题

    private var header: some View {
        HStack(spacing: 12) {
            ReaderCircleButton(systemName: "xmark", label: "关闭设置") {
                dismiss()
            }

            Text("主题与设置")
                .font(.system(size: 18, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)
        }
    }

    // MARK: - 字号 / 阅读方式 / 外观

    private var controlRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                fontSizePill
                fontDots
            }
            .frame(maxWidth: .infinity)

            iconPills
                .frame(width: 122)
        }
    }

    private var fontSizePill: some View {
        HStack(spacing: 0) {
            Button {
                adjustFont(by: -1)
            } label: {
                Text("小")
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(session.settings.fontSize <= Self.minFontSize)
            .accessibilityLabel("减小字号")

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 22)
                .accessibilityHidden(true)

            Button {
                adjustFont(by: 1)
            } label: {
                Text("大")
                    .font(.system(size: 20))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(session.settings.fontSize >= Self.maxFontSize)
            .accessibilityLabel("增大字号")
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(Int(session.settings.fontSize)) 点")
    }

    /// 字号刻度点。点「小 / 大」时短暂出现，用来显示当前档位。
    private var fontDots: some View {
        let step = Int((session.settings.fontSize - Self.minFontSize).rounded())

        return HStack(spacing: 3) {
            ForEach(0...Self.fontSteps, id: \.self) { index in
                Capsule()
                    .fill(
                        index <= step
                            ? session.settings.accent.color
                            : Color.primary.opacity(0.15)
                    )
                    .frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 6)
        .opacity(showFontDots ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: showFontDots)
        .accessibilityHidden(true)
    }

    private func adjustFont(by delta: Double) {
        let next = min(
            max(session.settings.fontSize + delta, Self.minFontSize),
            Self.maxFontSize
        )
        session.settings.fontSize = next

        showFontDots = true
        dotHideTask?.cancel()
        dotHideTask = Task {
            try? await Task<Never, Never>.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            showFontDots = false
        }
    }

    private var iconPills: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("阅读方式", selection: $session.settings.readingMode) {
                    Label("翻页", systemImage: "book.pages").tag(ReadingMode.paged)
                    Label("滚动", systemImage: "scroll").tag(ReadingMode.scroll)
                }
            } label: {
                Image(systemName: readingModeIcon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 61, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("翻页方式")

            Menu {
                Picker("外观", selection: appearanceBinding) {
                    Label("浅色", systemImage: "sun.max").tag(AppearanceChoice.light)
                    Label("深色", systemImage: "moon").tag(AppearanceChoice.dark)
                    Label("匹配设备", systemImage: "circle.lefthalf.filled").tag(AppearanceChoice.system)
                }
            } label: {
                Image(systemName: appearanceIcon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 61, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("外观")
        }
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var readingModeIcon: String {
        session.settings.readingMode == .scroll ? "scroll" : "book.pages"
    }

    private var appearanceIcon: String {
        if session.settings.followSystemAppearance { return "circle.lefthalf.filled" }
        return session.settings.theme.isDark ? "moon" : "sun.max"
    }

    /// 外观菜单的选中状态由「是否跟随系统 + 当前主题明暗」推导。
    private var appearanceBinding: Binding<AppearanceChoice> {
        Binding(
            get: {
                if session.settings.followSystemAppearance { return .system }
                return session.settings.theme.isDark ? .dark : .light
            },
            set: { applyAppearance($0) }
        )
    }

    private func applyAppearance(_ choice: AppearanceChoice) {
        switch choice {
        case .light:
            session.settings.followSystemAppearance = false
            session.settings.themeName = ReaderTheme.paper.name
        case .dark:
            session.settings.followSystemAppearance = false
            session.settings.themeName = ReaderTheme.night.name
        case .system:
            session.settings.followSystemAppearance = true
            session.settings.themeName = (colorScheme == .dark ? ReaderTheme.night : ReaderTheme.paper).name
        }
    }

    // MARK: - 亮度

    private var brightnessRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.min")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(value: $brightness, in: 0...1)
                .accessibilityLabel("屏幕亮度")
                .accessibilityValue("\(Int(brightness * 100))%")

            Image(systemName: "sun.max")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    // MARK: - 主题

    private var themeGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 12
        ) {
            ForEach(ReaderTheme.all) { theme in
                themeCard(theme)
            }
        }
    }

    private func themeCard(_ theme: ReaderTheme) -> some View {
        let isSelected = session.settings.themeName == theme.name
            && !session.settings.followSystemAppearance

        return Button {
            session.settings.followSystemAppearance = false
            session.settings.themeName = theme.name
        } label: {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("大")
                        .font(.system(size: 26, weight: .semibold))
                    Text("小")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(theme.textColor)

                Text(theme.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 86)
            .background(
                theme.backgroundColor,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.95) : Color.primary.opacity(0.10),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.displayName)主题")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 自定义

    private var customThemeButton: some View {
        Button {
            showCustomTheme = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .regular))
                Text("自定义")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 47)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("自定义主题")
    }
}
