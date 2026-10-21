//
//  TextEncodingDetectorTests.swift
//  ModuReaderTests
//

import Testing
import Foundation
@testable import ModuReader

@Suite("文本编码探测")
struct TextEncodingDetectorTests {

    // MARK: - BOM

    @Test("UTF-8 带 BOM")
    func utf8BOM() throws {
        let original = "第一章 测试\n这是中文内容。"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(original.data(using: .utf8)!)

        let result = TextEncodingDetector.detect(data: data)
        #expect(result.displayName.contains("BOM"))
        #expect(result.text == original)
        #expect(!result.hasReplacementCharacters)
    }

    @Test("UTF-16 LE 带 BOM")
    func utf16LEBOM() throws {
        let original = "第一章 测试\n中文内容"
        var data = Data([0xFF, 0xFE])
        data.append(original.data(using: .utf16LittleEndian)!)

        let result = TextEncodingDetector.detect(data: data)
        #expect(result.displayName.contains("UTF-16 LE"))
        #expect(result.text == original)
    }

    @Test("UTF-16 BE 带 BOM")
    func utf16BEBOM() throws {
        let original = "第一章 测试"
        var data = Data([0xFE, 0xFF])
        data.append(original.data(using: .utf16BigEndian)!)

        let result = TextEncodingDetector.detect(data: data)
        #expect(result.displayName.contains("UTF-16 BE"))
        #expect(result.text == original)
    }

    // MARK: - 无 BOM

    @Test("纯 UTF-8 中文")
    func utf8Chinese() throws {
        let original = "第一章 开始\n" + String(repeating: "这是一段中文测试内容。", count: 20)
        let data = original.data(using: .utf8)!

        let result = TextEncodingDetector.detect(data: data)
        #expect(result.text == original)
        #expect(!result.hasReplacementCharacters)
        #expect(!result.isFallback)
    }

    @Test("GB18030 中文")
    func gb18030Chinese() throws {
        let original = "第一章 开始\n" + String(repeating: "这是一段中文测试内容。", count: 20)
        let gbEncoding = TextEncodingDetector.encoding(from: .GB_18030_2000)
        guard let data = original.data(using: gbEncoding) else {
            Issue.record("无法用 GB18030 编码测试文本")
            return
        }

        let result = TextEncodingDetector.detect(data: data)
        #expect(result.text == original)
        #expect(result.displayName.contains("GB"))
    }

    @Test("Big5 繁体中文")
    func big5Chinese() throws {
        let original = "第一章 開始\n" + String(repeating: "這是一段繁體中文測試內容。", count: 20)
        let big5 = TextEncodingDetector.encoding(from: .big5)
        guard let data = original.data(using: big5) else {
            Issue.record("无法用 Big5 编码测试文本")
            return
        }

        let result = TextEncodingDetector.detect(data: data)
        #expect(result.text == original)
        #expect(result.displayName.contains("Big5"))
    }

    @Test("Shift-JIS 日文")
    func shiftJISJapanese() throws {
        let original = "第一章 はじまり\n" + String(repeating: "これは日本語のテストです。", count: 20)
        let shiftJIS = TextEncodingDetector.encoding(from: .shiftJIS)
        guard let data = original.data(using: shiftJIS) else {
            Issue.record("无法用 Shift-JIS 编码测试文本")
            return
        }

        let result = TextEncodingDetector.detect(data: data)
        #expect(result.text == original)
        #expect(result.displayName.contains("Shift"))
    }

    @Test("UTF-16 LE 无 BOM")
    func utf16LEWithoutBOM() throws {
        let original = "Chapter One\n" + String(repeating: "Some English text. ", count: 40)
        let data = original.data(using: .utf16LittleEndian)!

        let result = TextEncodingDetector.detect(data: data)
        #expect(result.text == original)
    }

    // MARK: - 边界

    @Test("空数据")
    func emptyData() {
        let result = TextEncodingDetector.detect(data: Data())
        #expect(result.text.isEmpty)
    }

    @Test("纯 ASCII")
    func asciiOnly() {
        let original = "Hello, world.\nSecond line."
        let result = TextEncodingDetector.detect(data: original.data(using: .utf8)!)
        #expect(result.text == original)
        #expect(!result.isFallback)
    }

    @Test("手动指定编码解码")
    func manualDecode() throws {
        let original = "手动编码测试内容。"
        let gbEncoding = TextEncodingDetector.encoding(from: .GB_18030_2000)
        guard let data = original.data(using: gbEncoding) else {
            Issue.record("无法编码测试文本")
            return
        }

        let decoded = TextEncodingDetector.decode(data: data, using: gbEncoding)
        #expect(decoded == original)
    }

    @Test("手动编码列表非空且包含常用项")
    func manualOptions() {
        #expect(TextEncodingDetector.manualOptions.count >= 8)
        let names = TextEncodingDetector.manualOptions.map(\.1)
        #expect(names.contains("UTF-8"))
        #expect(names.contains("GB18030"))
        #expect(names.contains("Big5"))
    }
}
