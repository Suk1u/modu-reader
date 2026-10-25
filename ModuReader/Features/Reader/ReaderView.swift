//
//  ReaderView.swift
//  ModuReader
//
//  阅读主界面。SwiftUI 负责功能层，UIKit 引擎负责阅读画布。
//
//  ── 交互 ──
//
//  单击正文：切换沉浸阅读（工具栏显隐）。
//  顶栏：关闭 / 状态胶囊 / 书签。
//  底栏：回跳（有跳转历史才出现）/ 页码胶囊 / 更多菜单。
//  右侧边缘：快速定位条，拖动时浮出章节名与目标页码。
//

import SwiftUI
import SwiftData
import UIKit

struct ReaderView: View {

    let book: BookDescriptor

    @Environment(AppContainer.self) private var appContainer
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var session: ReaderSession?
    @State private var showChrome = false
    @State private var showTOC = false
    @State private var showSettings = false
    @State private var showSearch = false
    /// 书签操作的临时提示，1.5 秒后回到常规状态文案。
    @State private var statusOverride: String?
    /// 阅读区亮度 0...1。1 为原始亮度，0 为最暗。
    @State private var brightness: Double = 1
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let session {
                session.theme.backgroundColor
                    .ignoresSafeArea()

                ReaderCanvas(engine: session.engine.hostViewController)
                    .ignoresSafeArea()

                // 亮度遮罩：只压暗画布，不参与任何交互。
                // 亮度越高遮罩越淡，滑块左暗右亮。
                Color.black
                    .opacity((1 - brightness) * 0.6)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if showChrome {
                    if session.settings.readingMode == .scroll {
                        ReaderScrubber(session: session, isActive: showChrome)
                            .ignoresSafeArea()
                    }

                    chromeOverlay(session: session)
                }

                undoOverlay(session: session)
                highlightPaletteOverlay(session: session)
            } else {
                ProgressView("正在打开…")
                    .task { await prepare() }
            }
        }
        .animation(
            .spring(response: 0.26, dampingFraction: 0.82),
            value: session?.pendingHighlight != nil
        )
        .statusBarHidden(!showChrome)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session?.stop()
            Task { await session?.saveProgress() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await session?.saveProgress() }
            }
        }
        .onChange(of: colorScheme) { _, scheme in
            applySystemAppearanceIfNeeded(scheme: scheme)
        }
        .alert("打开失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("返回", role: .cancel) { dismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showTOC) {
            if let session {
                TOCPanel(
                    session: session,
                    bookTitle: book.title,
                    pageText: pageText(for: session)
                ) {
                    showTOC = false
                    showChrome = false
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSettings) {
            if let session {
                ReaderSettingsPanel(session: session, brightness: $brightness)
                    .presentationDetents([.fraction(0.6)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color(uiColor: .systemBackground))
                    .presentationCornerRadius(38)
            }
        }
        .sheet(isPresented: $showSearch) {
            if let session {
                SearchPanel(session: session) { result in
                    session.go(to: result)
                    showChrome = false
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(uiColor: .systemBackground))
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private func chromeOverlay(session: ReaderSession) -> some View {
        VStack(spacing: 8) {
            ReaderTopBar(
                statusText: statusText(for: session),
                tint: .primary,
                isBookmarked: session.isBookmarked,
                onClose: {
                    Task {
                        await session.saveProgress()
                        dismiss()
                    }
                },
                onToggleBookmark: { toggleBookmark(session) }
            )

            Spacer(minLength: 0)

            ReaderBottomBar(
                pageText: pageText(for: session),
                tint: .primary,
                onOpenTOC: { presentPanel(.toc) },
                onOpenSearch: { presentPanel(.search) },
                onOpenSettings: { presentPanel(.settings) }
            )
        }
        .transition(.opacity)
    }

    /// 回跳按钮。单击在上一次位置之间来回，长按展开完整跳转历史。
    /// 只在工具栏可见时出现 —— 沉浸阅读时不打扰。
    @ViewBuilder
    private func undoOverlay(session: ReaderSession) -> some View {
        if showChrome, session.canReturnToJumpOrigin || session.canRedoJump {
            VStack {
                Spacer(minLength: 0)

                HStack {
                    Menu {
                        ForEach(session.jumpEntries) { entry in
                            Button("第 \(entry.page) 页") {
                                session.jump(to: entry.index)
                            }
                        }
                        if session.canRedoJump {
                            Divider()
                            Button("重做跳过页面") {
                                session.redoJump()
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 29, height: 29)
                            .frame(width: 50, height: 50)
                            .contentShape(.circle)
                            .glassEffect(
                                .regular.interactive(),
                                in: .rect(cornerRadius: 25, style: .continuous)
                            )
                            .glassEffectTransition(.materialize)
                    } primaryAction: {
                        withAnimation(.snappy(duration: 0.2)) {
                            if session.canReturnToJumpOrigin {
                                session.returnToJumpOrigin()
                            } else {
                                session.redoJump()
                            }
                        }
                    }
                    .accessibilityLabel("跳转记录")

                    Spacer(minLength: 0)
                }
                .padding(.leading, 29)
                .padding(.bottom, 1)
            }
            .transition(.opacity)
        }
    }

    /// 选中文字后的配色浮条，默认浮在选区**上方**。
    ///
    /// 贴着选区顶边往上放；上方放不下（选在页首）才翻到下方，
    /// 始终紧挨着正在标记的文字。浮条只在自己范围内接收触摸，
    /// 点外面的正文会由 WebView 的 tap 回调取消这次高亮。
    @ViewBuilder
    private func highlightPaletteOverlay(session: ReaderSession) -> some View {
        if session.pendingHighlight != nil {
            GeometryReader { proxy in
                // 与 HighlightPalette 的实际高度对齐（30pt 命中区 + 上下留白）。
                let paletteHeight: CGFloat = 46
                let rect = session.pendingHighlightRect
                let centerX = rect?.midX ?? proxy.size.width / 2
                let x = min(max(centerX, 160), proxy.size.width - 160)
                let y: CGFloat = {
                    guard let rect else { return proxy.size.height / 2 }
                    let above = rect.minY - paletteHeight / 2 - 8
                    if above >= paletteHeight / 2 + 12 { return above }
                    return rect.maxY + paletteHeight / 2 + 8
                }()

                HighlightPalette(
                    onPick: { hex, underline in
                        session.commitHighlight(tintHex: hex, underline: underline)
                    },
                    onCancel: { session.cancelPendingHighlight() }
                )
                .background {
                    // 整条浮条都吞掉点击：点到色点之间的空隙也不会穿到正文，
                    // 避免刚标记好的选区被 WebView 清掉。
                    Capsule()
                        .fill(Color.clear)
                        .contentShape(Capsule())
                        .onTapGesture { }
                }
                .position(
                    x: x,
                    y: min(max(y, paletteHeight / 2 + 8), proxy.size.height - paletteHeight / 2 - 8)
                )
                .animation(.easeOut(duration: 0.12), value: session.pendingHighlightRect)
            }
            .ignoresSafeArea()
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
        }
    }

    // MARK: - 面板

    private enum Panel {
        case toc
        case search
        case settings
    }

    private func presentPanel(_ panel: Panel) {
        switch panel {
        case .toc: showTOC = true
        case .search: showSearch = true
        case .settings: showSettings = true
        }
    }

    // MARK: - 文案

    private func statusText(for session: ReaderSession) -> String {
        if let statusOverride { return statusOverride }

        if let remaining = session.chapterRemainingPages {
            return remaining <= 0 ? "本章最后一页" : "本章还剩 \(remaining) 页"
        }
        if session.totalPageCount > 0 {
            return "第 \(max(session.currentPageNumber, 1))/\(session.totalPageCount) 页"
        }
        return "\(percent(session.totalProgression))"
    }

    private func pageText(for session: ReaderSession) -> String {
        if session.totalPageCount > 0 {
            return "\(max(session.currentPageNumber, 1))/\(session.totalPageCount)页"
        }
        return percent(session.totalProgression)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    private func toggleBookmark(_ session: ReaderSession) {
        session.toggleBookmark()
        let text = session.isBookmarked ? "书签：已添加" : "书签：已移除"
        statusOverride = text

        Task {
            try? await Task<Never, Never>.sleep(for: .seconds(1.5))
            if statusOverride == text {
                statusOverride = nil
            }
        }
    }

    /// 「匹配设备」时，主题要跟着当前明暗走。
    private func applySystemAppearanceIfNeeded(scheme: ColorScheme) {
        guard let session, session.settings.followSystemAppearance else { return }
        let target = scheme == .dark ? ReaderTheme.night : ReaderTheme.paper
        if session.settings.themeName != target.name {
            session.settings.themeName = target.name
        }
    }

    // MARK: - Prepare

    private func prepare() async {
        let fileStore = appContainer.fileStore
        let settings = appContainer.globalSettings

        // 全部走 Readium（WKWebView）：
        // - EPUB 直接加载原始文件，保留出版方 CSS 与内嵌字体
        // - TXT / Markdown 在打开时打包成标准 EPUB 再加载
        let engine: any RenderEngine = ReadiumEPUBEngine(fileStore: fileStore)
        let session = ReaderSession(
            book: book,
            engine: engine,
            settings: settings,
            modelContext: modelContext
        )

        // 设置变化回写全局，保证外观/强调色跨书、跨启动记忆
        session.onSettingsChange = { [appContainer] newSettings in
            appContainer.globalSettings = newSettings
        }

        session.onToggleChrome = {
            withAnimation(.easeOut(duration: 0.18)) {
                showChrome.toggle()
            }
        }

        do {
            try await session.start()
            self.session = session
            applySystemAppearanceIfNeeded(scheme: colorScheme)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - ReaderCanvas

/// UIKit 引擎的 SwiftUI 桥接。
///
/// 只负责托管 `UIViewController`，不参与任何阅读逻辑。
struct ReaderCanvas: UIViewControllerRepresentable {

    let engine: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        engine
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // 引擎自行管理内部状态，此处无需更新
    }
}