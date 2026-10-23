//
//  CustomThemePanel.swift
//  ModuReader
//
//  「自定义主题」面板。
//
//  顶部是实时预览：任何滑块变动都会立刻反映到预览卡片，
//  同时通过 ReaderSession 实时驱动阅读器正文。
//

import SwiftUI
import UIKit

struct CustomThemePanel: View {

    @Bindable var session: ReaderSession

    @Environment(\.dismiss) private var dismiss

    private static let sampleText = """
    晚饭过后，我沿着海滩散步，想找一个绝佳的位置读完手里的书，再开启一本新书。我发现了一个地方，目之所及，空无一人。这里还有一张吊床，可以阅读和小憩。我躺下来，几经调整，找到一个最舒适的姿势，就此遁入书中，沉浸在最后一个章节。
    """

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    textSection
                    layoutSection
                    resetButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("自定义主题")
            .navigationBarTitleDisplayMode(.inline)
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
                    .accessibilityLabel("关闭")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(width: 32, height: 32)
                            .background(Color.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("完成")
                }
            }
        }
    }

    // MARK: - 预览

    private var preview: some View {
        let theme = session.settings.theme

        return VStack(alignment: .leading, spacing: 10) {
            Text("大小")
                .font(.system(size: 32, weight: .bold))

            Text(Self.sampleText)
                .font(.system(size: session.settings.fontSize))
                .lineSpacing(max(0, (session.settings.lineHeightMultiple - 1) * session.settings.fontSize))
                .tracking(session.settings.letterSpacing)
                .lineLimit(7)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(theme.textColor)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.backgroundColor,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("排版预览")
    }

    // MARK: - 文本

    private var textSection: some View {
        section("文本") {
            fontRow

            if session.hasBookFont {
                Divider()
                Toggle(isOn: $session.settings.useBookFont) {
                    Label("使用书籍自带字体", systemImage: "textformat.abc")
                        .labelStyle(.titleAndIcon)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var fontRow: some View {
        Menu {
            Picker("字体", selection: $session.settings.fontFamily) {
                ForEach(ReaderFontFamily.allCases, id: \.self) { family in
                    Text(family.displayName).tag(family)
                }
            }
        } label: {
            HStack {
                Label("字体", systemImage: "textformat")
                Spacer(minLength: 8)
                Text(session.settings.fontFamily.displayName)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .disabled(session.settings.useBookFont && session.hasBookFont)
        .accessibilityLabel("字体")
        .accessibilityValue(session.settings.fontFamily.displayName)
    }

    // MARK: - 排版

    private var layoutSection: some View {
        section("排版") {
            SliderRow(
                title: "行间距",
                systemImage: "arrow.up.and.down.text.horizontal",
                value: $session.settings.lineHeightMultiple,
                range: 1.2...2.4,
                step: 0.1,
                display: String(format: "%.1f", session.settings.lineHeightMultiple)
            )
            Divider()
            SliderRow(
                title: "段间距",
                systemImage: "text.append",
                value: $session.settings.paragraphSpacing,
                range: 0...32,
                step: 2,
                display: "\(Int(session.settings.paragraphSpacing))"
            )
            Divider()
            SliderRow(
                title: "首行缩进",
                systemImage: "increase.indent",
                value: Binding(
                    get: { Double(session.settings.firstLineIndent) },
                    set: { session.settings.firstLineIndent = Int($0) }
                ),
                range: 0...4,
                step: 1,
                display: "\(session.settings.firstLineIndent) 字"
            )
            Divider()
            SliderRow(
                title: "页边空白",
                systemImage: "rectangle.inset.filled",
                value: $session.settings.horizontalPadding,
                range: 12...64,
                step: 4,
                display: "\(Int(session.settings.horizontalPadding))"
            )
        }
    }

    // MARK: - 还原

    private var resetButton: some View {
        Button(role: .destructive) {
            resetTypography()
        } label: {
            Text("还原主题")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityLabel("还原主题默认排版")
    }

    private func resetTypography() {
        let defaults = ReaderSettings()
        session.settings.fontSize = defaults.fontSize
        session.settings.lineHeightMultiple = defaults.lineHeightMultiple
        session.settings.paragraphSpacing = defaults.paragraphSpacing
        session.settings.firstLineIndent = defaults.firstLineIndent
        session.settings.letterSpacing = defaults.letterSpacing
        session.settings.horizontalPadding = defaults.horizontalPadding
        session.settings.fontFamily = defaults.fontFamily
    }

    // MARK: - 分组卡片

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }
}

// MARK: - 滑块行

private struct SliderRow: View {

    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    let display: String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 8)
                Text(display)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
        .padding(.vertical, 8)
    }
}