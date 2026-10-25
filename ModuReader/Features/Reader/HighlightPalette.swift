//
//  HighlightPalette.swift
//  ModuReader
//
//  选中文字后浮在选区上方的配色条：五个颜色 + 下划线。
//
//  点颜色 / 下划线时先亮起选中态，停一小段再落库 ——
//  浮条会在落库后收起，没有这段停留就看不到任何点击反馈。
//

import SwiftUI

struct HighlightPalette: View {

    let onPick: (String, Bool) -> Void
    let onCancel: () -> Void

    struct Swatch: Identifiable {
        let hex: String
        let color: Color
        var id: String { hex }
    }

    static let palette: [Swatch] = [
        Swatch(hex: "#FAC750", color: Color(red: 0.98, green: 0.78, blue: 0.31)),
        Swatch(hex: "#A8D672", color: Color(red: 0.66, green: 0.84, blue: 0.45)),
        Swatch(hex: "#8FC7F0", color: Color(red: 0.56, green: 0.78, blue: 0.94)),
        Swatch(hex: "#F0A0B0", color: Color(red: 0.94, green: 0.63, blue: 0.69)),
        Swatch(hex: "#C0A8E8", color: Color(red: 0.75, green: 0.66, blue: 0.91)),
    ]

    @State private var pickedHex: String?
    @State private var pickedUnderline = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.palette) { swatch in
                let isPicked = pickedHex == swatch.hex && !pickedUnderline

                Button {
                    pick(hex: swatch.hex, underline: false)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if isPicked {
                                Circle().strokeBorder(Color.white, lineWidth: 2)
                            }
                        }
                        .scaleEffect(isPicked ? 1.16 : 1)
                        // 视觉大小不变，命中区放大到 30pt，手指不用瞄准
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                        .animation(
                            .spring(response: 0.2, dampingFraction: 0.6),
                            value: isPicked
                        )
                }
                .buttonStyle(HighlightPaletteButtonStyle())
                .accessibilityLabel("高亮颜色")
            }

            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: 20)
                .accessibilityHidden(true)

            Button {
                pick(hex: Self.palette[0].hex, underline: true)
            } label: {
                Image(systemName: "underline")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(pickedUnderline ? Color.white : Color.primary)
                    .frame(width: 32, height: 32)
                    .background {
                        if pickedUnderline {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.3))
                        }
                    }
                    .contentShape(.rect)
                    .animation(.easeOut(duration: 0.15), value: pickedUnderline)
            }
            .buttonStyle(HighlightPaletteButtonStyle())
            .accessibilityLabel("下划线高亮")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    /// 先亮选中态，停 180ms 再落库并收起浮条。
    private func pick(hex: String, underline: Bool) {
        guard pickedHex == nil, !pickedUnderline else { return }
        pickedHex = hex
        pickedUnderline = underline

        Task { @MainActor in
            try? await Task<Never, Never>.sleep(for: .milliseconds(180))
            onPick(hex, underline)
        }
    }
}

/// 按压时放大并提亮，给颜色 / 下划线按钮一个明确的命中反馈。
private struct HighlightPaletteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.18 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(
                .spring(response: 0.22, dampingFraction: 0.6),
                value: configuration.isPressed
            )
    }
}