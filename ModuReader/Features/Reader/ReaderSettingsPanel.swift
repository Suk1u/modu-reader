//
//  ReaderSettingsPanel.swift
//  ModuReader
//
//  阅读设置面板。所有调整实时预览，关闭后保留。
//

import SwiftUI

struct ReaderSettingsPanel: View {

    @Bindable var session: ReaderSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                readingModeSection
                themeSection
                typographySection
                spacingSection
                fontFamilySection
            }
            .navigationTitle("主题与设置")
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
                    .accessibilityLabel("关闭设置")
                }
            }
        }
    }

    // MARK: - Sections

    private var readingModeSection: some View {
        Section("阅读方式") {
            Picker("阅读方式", selection: $session.settings.readingMode) {
                ForEach(ReadingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("阅读方式")
        }
    }

    private var themeSection: some View {
        Section("主题") {
            HStack(spacing: 14) {
                ForEach(ReaderTheme.all) { theme in
                    Button {
                        session.settings.themeName = theme.name
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(theme.backgroundColor)
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            session.settings.themeName == theme.name
                                                ? theme.accentColor
                                                : Color.secondary.opacity(0.25),
                                            lineWidth: session.settings.themeName == theme.name ? 2.5 : 1
                                        )
                                }
                                .overlay {
                                    if session.settings.themeName == theme.name {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(theme.textColor)
                                    }
                                }
                                .frame(width: 44, height: 44)

                            Text(theme.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.displayName)主题")
                    .accessibilityAddTraits(
                        session.settings.themeName == theme.name ? [.isSelected] : []
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var typographySection: some View {
        Section("字体大小") {
            HStack(spacing: 12) {
                Button {
                    session.settings.fontSize = max(12, session.settings.fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(session.settings.fontSize <= 12)
                .accessibilityLabel("减小字号")

                Slider(
                    value: $session.settings.fontSize,
                    in: 12...32,
                    step: 1
                )
                .accessibilityLabel("字号")
                .accessibilityValue("\(Int(session.settings.fontSize)) 点")

                Button {
                    session.settings.fontSize = min(32, session.settings.fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(session.settings.fontSize >= 32)
                .accessibilityLabel("增大字号")

                Text("\(Int(session.settings.fontSize))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }
        }
    }

    private var spacingSection: some View {
        Section("排版") {
            LabeledContent("行距") {
                Slider(
                    value: $session.settings.lineHeightMultiple,
                    in: 1.2...2.4,
                    step: 0.1
                )
                .frame(maxWidth: 180)
                .accessibilityValue(String(format: "%.1f 倍", session.settings.lineHeightMultiple))
            }

            LabeledContent("段间距") {
                Slider(
                    value: $session.settings.paragraphSpacing,
                    in: 0...32,
                    step: 2
                )
                .frame(maxWidth: 180)
                .accessibilityValue("\(Int(session.settings.paragraphSpacing)) 点")
            }

            LabeledContent("页边距") {
                Slider(
                    value: $session.settings.horizontalPadding,
                    in: 12...64,
                    step: 4
                )
                .frame(maxWidth: 180)
                .accessibilityValue("\(Int(session.settings.horizontalPadding)) 点")
            }

            Stepper(
                "首行缩进 \(session.settings.firstLineIndent) 字",
                value: $session.settings.firstLineIndent,
                in: 0...4
            )
            .accessibilityValue("\(session.settings.firstLineIndent) 字符")
        }
    }

    private var fontFamilySection: some View {
        Section("字体") {
            if session.hasBookFont {
                Toggle("使用书籍自带字体", isOn: $session.settings.useBookFont)
                    .accessibilityHint("使用 EPUB 内嵌的字体，覆盖下方选择")
            }

            Picker("字体", selection: $session.settings.fontFamily) {
                ForEach(ReaderFontFamily.allCases, id: \.self) { family in
                    Text(family.displayName).tag(family)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(session.settings.useBookFont && session.hasBookFont)
        }
    }
}
