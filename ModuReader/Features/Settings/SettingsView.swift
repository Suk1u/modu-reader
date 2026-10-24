//
//  SettingsView.swift
//  ModuReader
//

import SwiftUI

struct SettingsView: View {

    @Environment(AppContainer.self) private var appContainer

    var body: some View {
        @Bindable var appContainer = appContainer

        NavigationStack {
            Form {
                Section("阅读") {
                    LabeledContent("默认字号") {
                        Text("\(Int(appContainer.globalSettings.fontSize)) 点")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("默认主题") {
                        Text(appContainer.globalSettings.theme.displayName)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("默认字体") {
                        Text(appContainer.globalSettings.fontFamily.displayName)
                            .foregroundStyle(.secondary)
                    }

                    Picker("注释显示", selection: Binding(
                        get: { appContainer.globalSettings.noteDisplayMode },
                        set: { appContainer.globalSettings.noteDisplay = $0 }
                    )) {
                        ForEach(NoteDisplay.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("外观") {
                    Picker("外观", selection: $appContainer.appearanceOverride) {
                        Text("跟随系统").tag(ColorScheme?.none)
                        Text("浅色").tag(ColorScheme?.some(.light))
                        Text("深色").tag(ColorScheme?.some(.dark))
                    }

                    // 应用颜色决定按钮图标、书架进度等系统着色的强调色
                    ColorPicker(
                        "应用颜色",
                        selection: accentBinding,
                        supportsOpacity: false
                    )
                }

                Section("诊断") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("诊断日志", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        StageFile.purgeAll()
                    } label: {
                        Label("清理导入暂存文件", systemImage: "trash")
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("支持的格式", value: "TXT、Markdown")
                    LabeledContent("最低系统", value: "iOS 26.0")
                }

                Section {
                    Text("墨读专注于本地阅读，不收集任何数据，不联网。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { appContainer.globalSettings.accent.color },
            set: { newValue in
                guard let hex = newValue.hexString else { return }
                appContainer.globalSettings.accentHex = hex
            }
        )
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    let container = try! ModuModelContainer.makeInMemory()
    return SettingsView()
        .environment(AppContainer(modelContainer: container))
        .modelContainer(container)
}
