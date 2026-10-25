//
//  HighlightPalette.swift
//  ModuReader
//
//  选中文字后浮在选区下方的配色条：五个颜色 + 下划线。
//

import SwiftUI

struct HighlightPalette: View {

    let onPick: (String, Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(HighlightStyleSheet.palette) { swatch in
                Button {
                    onPick(swatch.hex, false)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("高亮颜色")
            }

            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: 20)
                .accessibilityHidden(true)

            Button {
                onPick(HighlightStyleSheet.palette[0].hex, true)
            } label: {
                Image(systemName: "underline")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下划线高亮")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
    }
}