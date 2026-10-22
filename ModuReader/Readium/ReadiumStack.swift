//
//  ReadiumStack.swift
//  ModuReader
//
//  Readium 服务容器。
//
//  只使用 Readium 的三个核心模块：
//  - ReadiumShared   共享模型（Publication / Locator / Link）
//  - ReadiumStreamer 解析 EPUB 为 Publication
//  - ReadiumNavigator 渲染（EPUBNavigatorViewController，基于 WKWebView）
//
//  为什么改用 Readium 渲染 EPUB：
//  自研的 TextKit 管线只能近似还原 EPUB —— CSS 字体、@font-face、
//  图文混排、复杂排版都会失真。Readium 的 EPUBNavigator 用 WKWebView
//  加载原始 XHTML + 出版方 CSS，保真度与桌面阅读器一致。
//

import Foundation
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

/// Readium 服务容器。
@MainActor
final class ReadiumStack {

    static let shared = ReadiumStack()

    private let httpClient: HTTPClient
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    private init() {
        let client = DefaultHTTPClient()
        let retriever = AssetRetriever(httpClient: client)
        self.httpClient = client
        self.assetRetriever = retriever
        self.publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: client,
                assetRetriever: retriever,
                pdfFactory: DefaultPDFDocumentFactory()
            ),
            contentProtections: []
        )
    }

    /// 打开一本本地 EPUB。
    ///
    /// - Parameter url: 沙盒内的 .epub 文件路径。
    func openPublication(at url: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else {
            throw ReadiumStackError.invalidURL
        }

        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL) {
        case .success(let retrieved):
            asset = retrieved
        case .failure(let error):
            throw ReadiumStackError.retrieveFailed(error.localizedDescription)
        }

        switch await publicationOpener.open(asset: asset, allowUserInteraction: false) {
        case .success(let publication):
            return publication
        case .failure(let error):
            throw ReadiumStackError.openFailed(error.localizedDescription)
        }
    }
}

enum ReadiumStackError: LocalizedError {
    case invalidURL
    case retrieveFailed(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "书籍路径无效。"
        case .retrieveFailed(let reason):
            "读取书籍失败：\(reason)"
        case .openFailed(let reason):
            "解析书籍失败：\(reason)"
        }
    }
}