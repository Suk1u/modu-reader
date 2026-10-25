//
//  HighlightPalette.swift
//  ModuReader
//
//  选中文字后浮在选区上方的配色条：五个颜色 + 下划线。
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

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.palette) { swatch in
                Button {
                    onPick(swatch.hex, false)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 22, height: 22)
                        // 视觉大小不变，命中区放大到 30pt，手指不用瞄准
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(HighlightPaletteButtonStyle())
                .accessibilityLabel("高亮颜色")
            }

            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: 20)
                .accessibilityHidden(true)

            Button {
                onPick(Self.palette[0].hex, true)
            } label: {
                Image(systemName: "underline")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(HighlightPaletteButtonStyle())
            .accessibilityLabel("下划线高亮")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
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
