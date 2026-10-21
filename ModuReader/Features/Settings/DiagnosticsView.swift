//
//  DiagnosticsView.swift
//  ModuReader
//
//  诊断日志查看器。导入失败时用户可从这里复制日志反馈。
//

import SwiftUI

struct DiagnosticsView: View {

    @State private var entries: [String] = []
    @State private var refreshTimer: Timer?

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("暂无日志", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("尝试导入一次文件后回到这里查看。")
                }
            } else {
                Section {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("\(entries.count) 条记录")
                }
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        UIPasteboard.general.string = entries.joined(separator: "\n")
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                    .disabled(entries.isEmpty)

                    Button(role: .destructive) {
                        Diagnostics.clear()
                        entries = []
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .disabled(entries.isEmpty)
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func refresh() {
        let latest = Diagnostics.snapshot()
        if latest != entries {
            entries = latest
        }
    }
}
