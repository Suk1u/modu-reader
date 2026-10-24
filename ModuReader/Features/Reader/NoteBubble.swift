//
//  NoteBubble.swift
//  ModuReader
//
//  脚注气泡。点正文里的「注」时弹出，显示注释内容。
//

import SwiftUI

struct NoteBubbleView: View {

    /// 被注释的原文片段，作为上下文提示。
    let referrer: String
    /// 注释正文。
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !referrer.isEmpty {
                Text(referrer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(content)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("注释")
        .accessibilityValue(content)
    }
}