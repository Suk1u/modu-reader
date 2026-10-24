//
//  CustomThemePanel.swift
//  ModuReader
//
//  「自定义主题」面板。
//
//  尺寸取自 iOS 26 Apple Books 实测规范：
//  预览区高 190pt、分组卡片圆角 20、标准行高 52、
//  滑块单元高 84（标题 13pt + 图标 22 + 数值 14pt 等宽 48pt 宽）。
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
                .padding(.horizontal, 18)
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
                    }
                    .accessibilityLabel("关闭")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 44, height: 44)
                            .background(Color.white, in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                            }
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
        let previewSize = min(session.settings.fontSize, 20)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("大").font(.system(size: 28, weight: .semibold))
                Text("小").font(.system(size: 15, weight: .semibold))
            }

            Text(Self.sampleText)
                .font(.system(size: previewSize))
                .lineSpacing(max(0, (session.settings.lineHeightMultiple - 1) * previewSize))
                .tracking(session.settings.letterSpacing)
                .lineLimit(7)
                .multilineTextAlignment(.leading)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .foregroundStyle(theme.textColor)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 190, alignment: .topLeading)
        .background(
            theme.backgroundColor,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("排版预览")
    }

    // MARK: - 文本

    private var textSection: some View {
        section("文本") {
            fontRow

            if session.hasBookFont {
                Divider().padding(.leading, 16)
                Toggle(isOn: $session.settings.useBookFont) {
                    Label("使用书籍自带字体", systemImage: "textformat.abc")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 16))
                }
                .frame(minHeight: 52)
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
            HStack(spacing: 12) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 20))
                    .frame(width: 28)
                Text("字体")
                    .font(.system(size: 16))
                Spacer(minLength: 8)
                Text(session.settings.fontFamily.displayName)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .disabled(session.settings.useBookFont && session.hasBookFont)
        .accessibilityLabel("字体")
        .accessibilityValue(session.settings.fontFamily.displayName)
    }

    // MARK: - 排版

    private var layoutSection: some View {
        section("无障碍与布局选项") {
            SliderRow(
                title: "行间距",
                systemImage: "arrow.up.and.down.text.horizontal",
                value: $session.settings.lineHeightMultiple,
                range: 1.2...2.4,
                step: 0.1,
                display: String(format: "%.2f", session.settings.lineHeightMultiple)
            )
            Divider().padding(.leading, 16)
            SliderRow(
                title: "段间距",
                systemImage: "text.append",
                value: $session.settings.paragraphSpacing,
                range: 0...32,
                step: 2,
                display: "\(Int(session.settings.paragraphSpacing))"
            )
            Divider().padding(.leading, 16)
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
            Divider().padding(.leading, 16)
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(red: 1.0, green: 0.271, blue: 0.227))
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: Capsule()
        )
        .accessibilityLabel("还原主题默认排版")
        .padding(.top, 4)
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
                .font(.system(size: 15, weight: .bold))
                .padding(.leading, 10)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .frame(width: 22)

                Slider(value: $value, in: range, step: step)
                    .accessibilityLabel(title)
                    .accessibilityValue(display)

                Text(display)
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 84, alignment: .center)
    }
}