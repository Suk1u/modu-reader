//
//  ReaderView.swift
//  ModuReader
//
//  阅读主界面。SwiftUI 负责功能层，UIKit 引擎负责阅读画布。
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

    @State private var session: ReaderSession?
    @State private var showChrome = false
    @State private var showTOC = false
    @State private var showSettings = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let session {
                session.theme.backgroundColor
                    .ignoresSafeArea()

                ReaderCanvas(engine: session.engine)
                    .ignoresSafeArea(edges: [.horizontal])

                chromeOverlay(session: session)
            } else {
                ProgressView("正在打开…")
                    .task { await prepare() }
            }
        }
        .statusBarHidden(!showChrome)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await session?.saveProgress() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                Task { await session?.saveProgress() }
            }
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
                TOCPanel(session: session) {
                    showTOC = false
                    showChrome = false
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSettings) {
            if let session {
                ReaderSettingsPanel(session: session)
                    .presentationDetents([.height(420), .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private func chromeOverlay(session: ReaderSession) -> some View {
        if showChrome {
            VStack(spacing: 0) {
                ReaderTopBar(
                    title: book.title,
                    onBack: {
                        Task {
                            await session.saveProgress()
                            dismiss()
                        }
                    },
                    onOpenTOC: { showTOC = true },
                    onToggleChrome: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showChrome = false
                        }
                    }
                )

                Spacer(minLength: 0)

                ReaderBottomBar(
                    session: session,
                    onOpenSettings: { showSettings = true }
                )
            }
            .transition(.opacity)
        }
    }

    // MARK: - Prepare

    private func prepare() async {
        let fileStore = appContainer.fileStore
        let settings = appContainer.globalSettings

        let engine = TextKitEngine(fileStore: fileStore)
        let session = ReaderSession(
            book: book,
            engine: engine,
            settings: settings,
            modelContext: modelContext
        )

        session.onToggleChrome = {
            withAnimation(.easeOut(duration: 0.18)) {
                showChrome.toggle()
            }
        }

        do {
            try await session.start()
            self.session = session
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
