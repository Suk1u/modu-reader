//
//  TextEncodingDetector.swift
//  ModuReader
//
//  纯文本编码探测。`NSString(contentsOf:usedEncoding:)` 对 GBK 常误判为 UTF-8，
//  因此必须使用显式探测链。
//

import Foundation

/// 文本编码探测结果。
struct EncodingDetectionResult: Equatable, Sendable {
    /// 探测到的编码。
    var encoding: String.Encoding
    /// 供界面展示的名称。
    var displayName: String
    /// 解码后的文本。
    var text: String
    /// 是否含替换字符（解码质量存疑）。
    var hasReplacementCharacters: Bool
    /// 是否由兜底策略得出（此时应提示用户手动切换）。
    var isFallback: Bool
}

/// 纯文本编码探测。
///
/// 探测顺序不可调换：
/// 1. BOM
/// 2. UTF-8 严格校验
/// 3. UTF-16 无 BOM 启发
/// 4. GB18030 → Big5 → GBK（中文优先）
/// 5. Shift-JIS → EUC-JP
/// 6. EUC-KR
/// 7. Windows-1252
/// 8. 兜底 UTF-8
enum TextEncodingDetector {

    /// 探测只读取前 64KB，避免大文件全量扫描。
    static let probeByteLimit = 64 * 1024

    /// 中文判定阈值：中文字符占比需高于此值。
    static let chineseCharacterRatioThreshold = 0.15
    /// 控制字符占比上限。
    static let controlCharacterRatioLimit = 0.01

    // MARK: - Public

    /// 探测并解码。
    ///
    /// - Parameter data: 原始文件字节。
    /// - Returns: 探测结果。若全部策略失败，返回 UTF-8 兜底结果（`isFallback == true`）。
    static func detect(data: Data) -> EncodingDetectionResult {
        let probe = data.prefix(probeByteLimit)

        // 1. BOM
        if let bomResult = detectByBOM(data: data) {
            return bomResult
        }

        // 2. UTF-8 严格校验
        if let utf8Text = strictUTF8(data) {
            return EncodingDetectionResult(
                encoding: .utf8,
                displayName: "UTF-8",
                text: utf8Text,
                hasReplacementCharacters: false,
                isFallback: false
            )
        }

        // 3. UTF-16 无 BOM 启发
        if let utf16 = detectUTF16WithoutBOM(probe: probe, data: data) {
            return utf16
        }

        // 4. 中文优先
        let chineseCandidates: [(String.Encoding, String)] = [
            (encoding(from: .GB_18030_2000), "GB18030"),
            (encoding(from: .big5), "Big5"),
            (encoding(from: .GB_2312_80), "GBK"),
        ]
        for (encoding, name) in chineseCandidates {
            if let result = evaluate(data: data, encoding: encoding, displayName: name) {
                return result
            }
        }

        // 5. 日文
        let japaneseCandidates: [(String.Encoding, String)] = [
            (encoding(from: .shiftJIS), "Shift-JIS"),
            (encoding(from: .EUC_JP), "EUC-JP"),
        ]
        for (encoding, name) in japaneseCandidates {
            if let result = evaluateJapanese(data: data, encoding: encoding, displayName: name) {
                return result
            }
        }

        // 6. 韩文
        if let result = evaluateKorean(data: data, encoding: encoding(from: .EUC_KR), displayName: "EUC-KR") {
            return result
        }

        // 7. 西文
        if let result = evaluateWestern(data: data, encoding: .windowsCP1252, displayName: "Windows-1252") {
            return result
        }

        // 8. 兜底
        let fallback = String(decoding: data, as: UTF8.self)
        return EncodingDetectionResult(
            encoding: .utf8,
            displayName: "UTF-8（兜底）",
            text: fallback,
            hasReplacementCharacters: fallback.contains("\u{FFFD}"),
            isFallback: true
        )
    }

    /// 按指定编码解码，用于用户在设置中手动覆盖。
    static func decode(data: Data, using encoding: String.Encoding) -> String? {
        guard let text = String(data: data, encoding: encoding) else { return nil }
        return text
    }

    /// 可手动选择的编码列表。
    static let manualOptions: [(String.Encoding, String)] = [
        (.utf8, "UTF-8"),
        (encoding(from: .GB_18030_2000), "GB18030"),
        (encoding(from: .GB_2312_80), "GBK"),
        (encoding(from: .big5), "Big5"),
        (.utf16LittleEndian, "UTF-16 LE"),
        (.utf16BigEndian, "UTF-16 BE"),
        (encoding(from: .shiftJIS), "Shift-JIS"),
        (encoding(from: .EUC_JP), "EUC-JP"),
        (encoding(from: .EUC_KR), "EUC-KR"),
        (.windowsCP1252, "Windows-1252"),
        (.isoLatin1, "ISO-8859-1"),
    ]

    // MARK: - BOM

    private static func detectByBOM(data: Data) -> EncodingDetectionResult? {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count >= 2 else { return nil }

        let encoding: String.Encoding
        let name: String
        let bomLength: Int

        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            encoding = .utf8
            name = "UTF-8 (BOM)"
            bomLength = 3
        } else if bytes[0] == 0xFF && bytes[1] == 0xFE {
            // UTF-32LE 也会以此开头，但纯文本阅读器不处理 UTF-32
            encoding = .utf16LittleEndian
            name = "UTF-16 LE (BOM)"
            bomLength = 2
        } else if bytes[0] == 0xFE && bytes[1] == 0xFF {
            encoding = .utf16BigEndian
            name = "UTF-16 BE (BOM)"
            bomLength = 2
        } else {
            return nil
        }

        let payload = data.dropFirst(bomLength)
        guard let text = String(data: Data(payload), encoding: encoding) else {
            return nil
        }
        return EncodingDetectionResult(
            encoding: encoding,
            displayName: name,
            text: text,
            hasReplacementCharacters: text.contains("\u{FFFD}"),
            isFallback: false
        )
    }

    // MARK: - UTF-8

    /// 严格 UTF-8 校验：解码成功且不含替换字符。
    private static func strictUTF8(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }
        // 纯 ASCII 也走这里，属正确结果
        return text
    }

    // MARK: - UTF-16 启发

    private static func detectUTF16WithoutBOM(probe: Data, data: Data) -> EncodingDetectionResult? {
        let bytes = [UInt8](probe)
        guard bytes.count >= 16 else { return nil }

        var zeroAtEven = 0
        var zeroAtOdd = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            if index % 2 == 0 { zeroAtEven += 1 } else { zeroAtOdd += 1 }
        }

        let half = bytes.count / 2
        guard half > 0 else { return nil }
        let evenRatio = Double(zeroAtEven) / Double(half)
        let oddRatio = Double(zeroAtOdd) / Double(half)

        let encoding: String.Encoding
        let name: String
        if oddRatio > 0.3 && evenRatio < 0.05 {
            // ASCII 字符高字节为 0，位于奇数位 → UTF-16LE
            encoding = .utf16LittleEndian
            name = "UTF-16 LE"
        } else if evenRatio > 0.3 && oddRatio < 0.05 {
            encoding = .utf16BigEndian
            name = "UTF-16 BE"
        } else {
            return nil
        }

        guard let text = String(data: data, encoding: encoding) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }
        return EncodingDetectionResult(
            encoding: encoding,
            displayName: name,
            text: text,
            hasReplacementCharacters: false,
            isFallback: false
        )
    }

    // MARK: - 评估

    private static func evaluate(
        data: Data,
        encoding: String.Encoding,
        displayName: String
    ) -> EncodingDetectionResult? {
        guard let text = String(data: data, encoding: encoding) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }

        let sample = String(text.prefix(4096))
        guard !sample.isEmpty else { return nil }

        let total = Double(sample.count)
        guard total > 0 else { return nil }

        var chinese = 0
        var control = 0
        for scalar in sample.unicodeScalars {
            let value = scalar.value
            // CJK 统一表意文字 + 扩展 A
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                chinese += 1
            }
            // 除常见空白外的 C0/C1 控制字符
            if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D {
                control += 1
            }
            if (0x7F...0x9F).contains(value) {
                control += 1
            }
        }

        let chineseRatio = Double(chinese) / total
        let controlRatio = Double(control) / total

        guard controlRatio < controlCharacterRatioLimit else { return nil }
        guard chineseRatio > chineseCharacterRatioThreshold else { return nil }

        return EncodingDetectionResult(
            encoding: encoding,
            displayName: displayName,
            text: text,
            hasReplacementCharacters: false,
            isFallback: false
        )
    }

    private static func evaluateJapanese(
        data: Data,
        encoding: String.Encoding,
        displayName: String
    ) -> EncodingDetectionResult? {
        guard let text = String(data: data, encoding: encoding) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }

        let sample = String(text.prefix(4096))
        guard !sample.isEmpty else { return nil }

        let total = Double(sample.count)
        guard total > 0 else { return nil }

        var japanese = 0
        var control = 0
        for scalar in sample.unicodeScalars {
            let value = scalar.value
            // 平假名 + 片假名 + 半角片假名
            if (0x3040...0x30FF).contains(value) || (0xFF66...0xFF9D).contains(value) {
                japanese += 1
            }
            if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D {
                control += 1
            }
            if (0x7F...0x9F).contains(value) {
                control += 1
            }
        }

        let japaneseRatio = Double(japanese) / total
        let controlRatio = Double(control) / total

        guard controlRatio < controlCharacterRatioLimit else { return nil }
        guard japaneseRatio > 0.05 else { return nil }

        return EncodingDetectionResult(
            encoding: encoding,
            displayName: displayName,
            text: text,
            hasReplacementCharacters: false,
            isFallback: false
        )
    }

    private static func evaluateKorean(
        data: Data,
        encoding: String.Encoding,
        displayName: String
    ) -> EncodingDetectionResult? {
        guard let text = String(data: data, encoding: encoding) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }

        let sample = String(text.prefix(4096))
        guard !sample.isEmpty else { return nil }

        let total = Double(sample.count)
        guard total > 0 else { return nil }

        var korean = 0
        var control = 0
        for scalar in sample.unicodeScalars {
            let value = scalar.value
            // 谚文音节 + 字母
            if (0xAC00...0xD7AF).contains(value) || (0x1100...0x11FF).contains(value) {
                korean += 1
            }
            if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D {
                control += 1
            }
            if (0x7F...0x9F).contains(value) {
                control += 1
            }
        }

        let koreanRatio = Double(korean) / total
        let controlRatio = Double(control) / total

        guard controlRatio < controlCharacterRatioLimit else { return nil }
        guard koreanRatio > 0.05 else { return nil }

        return EncodingDetectionResult(
            encoding: encoding,
            displayName: displayName,
            text: text,
            hasReplacementCharacters: false,
            isFallback: false
        )
    }

    /// 西文兜底：控制字符少即可。
    private static func evaluateWestern(
        data: Data,
        encoding: String.Encoding,
        displayName: String
    ) -> EncodingDetectionResult? {
        guard let text = String(data: data, encoding: encoding) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }

        let sample = String(text.prefix(4096))
        guard !sample.isEmpty else { return nil }

        let total = Double(sample.count)
        guard total > 0 else { return nil }

        var control = 0
        for scalar in sample.unicodeScalars {
            let value = scalar.value
            if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D {
                control += 1
            }
        }

        guard Double(control) / total < controlCharacterRatioLimit else { return nil }

        return EncodingDetectionResult(
            encoding: encoding,
            displayName: displayName,
            text: text,
            hasReplacementCharacters: false,
            isFallback: false
        )
    }

    // MARK: - CFStringEncoding 桥接

    /// 把 `CFStringEncodings` 转换为 `String.Encoding`。
    ///
    /// Foundation 未直接暴露 GB18030 / GBK / Big5 / Shift-JIS 等编码常量，
    /// 必须通过 CoreFoundation 转换。
    static func encoding(from cfEncoding: CFStringEncodings) -> String.Encoding {
        let cfValue = CFStringEncoding(cfEncoding.rawValue)
        let nsValue = CFStringConvertEncodingToNSStringEncoding(cfValue)
        return String.Encoding(rawValue: nsValue)
    }
}
