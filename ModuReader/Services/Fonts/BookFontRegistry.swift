//
//  BookFontRegistry.swift
//  ModuReader
//
//  注册书籍自带的字体，供正文排版使用。
//
//  EPUB 常内嵌自定义字体（如 NotoSans.ttf、Shangtu.ttf）。
//  iOS 不会自动识别沙盒里的字体文件，必须用
//  `CTFontManagerRegisterFontsForURL` 显式注册。
//

import Foundation
import CoreText
import UIKit

/// 书籍字体注册表。
///
/// 线程约束：`@MainActor`。字体注册会修改进程级状态，不宜并发。
@MainActor
final class BookFontRegistry {

    /// 已注册的字体：PostScript 名 → 文件 URL。
    private(set) var registeredFonts: [String: URL] = [:]

    /// 按字重排序后的可用字体名。
    private(set) var availableFontNames: [String] = []

    /// 注册一本书目录下的全部字体。
    ///
    /// - Parameter bookDirectory: 书籍根目录（`Books/<bookID>/`）。
    func registerFonts(in bookDirectory: URL) {
        let fontsDirectory = bookDirectory.appendingPathComponent("extracted", isDirectory: true)
        guard FileManager.default.fileExists(atPath: fontsDirectory.path) else { return }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: fontsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var registered: [String: URL] = [:]

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ["ttf", "otf", "ttc", "otc"].contains(ext) else { continue }

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            // 注册到当前进程。scope 用 .process：
            // .persistent 需要重启 App 才生效，不适合按书注册。
            var error: Unmanaged<CFError>?
            let success = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &error
            )

            // 注册失败不直接放弃：字体可能已在上一轮注册过，
            // 此时仍能通过描述符拿到 PostScript 名。
            // 之前在这里 continue 导致「有时有字体选项、有时没有」——
            // 取决于本次进程是否首次注册该字体。
            if !success {
                let message = error?.takeRetainedValue().localizedDescription ?? "未知原因"
                Diagnostics.log("字体注册返回 false（继续尝试读取）: \(url.lastPathComponent) — \(message)")
            }

            // 读取字体的 PostScript 名
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let postScriptName = CTFontDescriptorCopyAttribute(
                    descriptor,
                    kCTFontNameAttribute
                  ) as? String else {
                Diagnostics.log("字体描述符读取失败: \(url.lastPathComponent)")
                continue
            }

            registered[postScriptName] = url
            Diagnostics.log("字体已注册: \(postScriptName) (\(url.lastPathComponent))")
        }

        registeredFonts = registered
        availableFontNames = registered.keys.sorted()
    }

    /// 清空记录。字体本身无法从进程注销，这里只清缓存。
    func reset() {
        registeredFonts.removeAll()
        availableFontNames.removeAll()
    }

    /// 取第一个已注册的字体名，用于正文默认字体。
    var primaryFontName: String? {
        availableFontNames.first
    }
}
