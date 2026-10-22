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

            if !success {
                // 已注册过不算失败
                let message = error?.takeRetainedValue().localizedDescription ?? "未知原因"
                if !message.contains("already registered") {
                    Diagnostics.log("字体注册失败 \(url.lastPathComponent): \(message)")
                    continue
                }
            }

            // 读取字体的 PostScript 名
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let postScriptName = CTFontDescriptorCopyAttribute(
                    descriptor,
                    kCTFontNameAttribute
                  ) as? String else {
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
