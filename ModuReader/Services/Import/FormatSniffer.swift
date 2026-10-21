//
//  FormatSniffer.swift
//  ModuReader
//
//  按扩展名 + 魔数嗅探真实格式。不信任扩展名。
//

import Foundation
import UniformTypeIdentifiers

/// 嗅探出的真实格式。
enum DetectedFormat: String, Sendable {
    case plainText
    case markdown
    case epub
    case pdf
    case zip
    case rar
    case sevenZip
    case imageFolder
    case unknown

    /// 是否为本期（M1）支持的格式。
    var isSupportedInCurrentMilestone: Bool {
        switch self {
        case .plainText, .markdown:
            true
        default:
            false
        }
    }
}

enum FormatSniffer {

    /// 读前 16 字节判定魔数。
    static func sniff(url: URL) -> DetectedFormat {
        if isDirectory(url) {
            return .imageFolder
        }

        let header = readHeader(url: url, byteCount: 16)
        let ext = url.pathExtension.lowercased()

        // 魔数优先
        if let header {
            if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
                // ZIP 系：需进一步区分 EPUB / 普通 ZIP
                return ext == "epub" ? .epub : .zip
            }
            if header.starts(with: [0x25, 0x50, 0x44, 0x46]) { // %PDF
                return .pdf
            }
            if header.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { // Rar!
                return .rar
            }
            if header.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { // 7z
                return .sevenZip
            }
        }

        // 无魔数，按扩展名
        switch ext {
        case "txt", "text":
            return .plainText
        case "md", "markdown":
            return .markdown
        case "epub":
            return .epub
        case "pdf":
            return .pdf
        case "cbz":
            return .zip
        case "cbr":
            return .rar
        case "cb7":
            return .sevenZip
        default:
            break
        }

        // 文本启发：前 1KB 不含 NUL 字节，且能按某种编码解码
        if let sample = readHeader(url: url, byteCount: 1024) {
            if !sample.contains(0) {
                return .plainText
            }
        }

        return .unknown
    }

    /// 文件选择器允许的类型。
    ///
    /// 必须覆盖所有「扩展名存在但系统 UTI 不识别」的情况。
    /// 例如 `.txt` 在部分系统上会被识别成 `public.plain-text`，
    /// 而某些网文下载得到的 `.txt` 实际 MIME 是 `public.data`；
    /// 若只用 `.plainText`，文件在选择器里会变灰不可选 —— 用户看到的就是「选了没反应」。
    static var supportedContentTypes: [UTType] {
        var types: [UTType] = [
            .plainText,
            .text,
            .data,          // 兜底：允许选择任何数据文件，导入后再按魔数判定
        ]

        let extensionTypes = ["txt", "text", "md", "markdown", "epub"]
        for ext in extensionTypes {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }

        return types
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    private static func readHeader(url: URL, byteCount: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: byteCount)
    }
}
