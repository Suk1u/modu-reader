//
//  HighlightStyleSheet.swift
//  ModuReader
//
//  选中文字后选高亮颜色与样式。
//

import SwiftUI

struct HighlightStyleSheet: View {

    let onConfirm: (String?, Bool) -> Void
    let onCancel: () -> Void

    @State private var colorHex: String = HighlightStyleSheet.palette[0].hex
    @State private var underline = false

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
        VStack(spacing: 18) {
            Text("高亮标记")
                .font(.system(size: 17, weight: .semibold))

            HStack(spacing: 14) {
                ForEach(Self.palette) { swatch in
                    Button {
                        colorHex = swatch.hex
                    } label: {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 36, height: 36)
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        colorHex == swatch.hex ? Color.primary : Color.clear,
                                        lineWidth: 2.5
                                    )
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("颜色 \(swatch.hex)")
                    .accessibilityAddTraits(colorHex == swatch.hex ? [.isSelected] : [])
                }
            }

            Toggle("使用下划线", isOn: $underline)
                .font(.system(size: 16))
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button {
                    onCancel()
                } label: {
                    Text("取消")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)

                Button {
                    onConfirm(colorHex, underline)
                } label: {
                    Text("完成")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
        .presentationDetents([.height(240)])
    }
}