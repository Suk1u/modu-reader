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

    /// 日文判定阈值：假名占比需高于此值。
    ///
    /// 取 3%：正常日文假名占比通常在 30% 以上，而中文文本几乎为 0。
    /// 阈值定得低，是为了兼容以汉字为主的汉文训读体日文。
    static let kanaRatioThreshold = 0.03
    /// 控制字符占比上限。
    static let controlCharacterRatioLimit = 0.01

    // MARK: - Public

    /// 探测并解码。
    ///
    /// 两阶段策略：
    /// 1. 只用前 64KB 判断编码（避免对 5MB 文件做 6 次全文解码）。
    /// 2. 确定编码后再对全文解码一次。
    ///
    /// - Parameter data: 原始文件字节。
    /// - Returns: 探测结果。若全部策略失败，返回 UTF-8 兜底结果（`isFallback == true`）。
    static func detect(data: Data) -> EncodingDetectionResult {
        // 小文件直接走完整流程，省一次切片
        guard data.count > probeByteLimit else {
            return detectFull(data: data)
        }

        // 大文件：先探测编码
        guard let encoding = probeEncoding(data: data) else {
            let fallback = String(decoding: data, as: UTF8.self)
            return EncodingDetectionResult(
                encoding: .utf8,
                displayName: "UTF-8（兜底）",
                text: fallback,
                hasReplacementCharacters: fallback.contains("\u{FFFD}"),
                isFallback: true
            )
        }

        // 用探测结果解码全文
        guard let text = String(data: data, encoding: encoding.encoding) else {
            let fallback = String(decoding: data, as: UTF8.self)
            return EncodingDetectionResult(
                encoding: .utf8,
                displayName: "UTF-8（兜底）",
                text: fallback,
                hasReplacementCharacters: true,
                isFallback: true
            )
        }

        return EncodingDetectionResult(
            encoding: encoding.encoding,
            displayName: encoding.displayName,
            text: text,
            hasReplacementCharacters: text.contains("\u{FFFD}"),
            isFallback: false
        )
    }

    /// 只判断编码，不解码全文。
    ///
    /// - Returns: 探测到的编码；无法判断时返回 nil。
    static func probeEncoding(data: Data) -> (encoding: String.Encoding, displayName: String)? {
        let probe = Data(data.prefix(probeByteLimit))

        if let bom = detectByBOM(data: probe) {
            return (bom.encoding, bom.displayName)
        }

        if let utf16 = detectUTF16WithoutBOM(probe: probe, data: probe) {
            return (utf16.encoding, utf16.displayName)
        }

        if strictUTF8(probe) != nil {
            return (.utf8, "UTF-8")
        }

        if let cjk = bestCJKCandidate(data: probe) {
            return (cjk.encoding, cjk.displayName)
        }

        if let korean = evaluateKorean(
            data: probe,
            encoding: encoding(from: .EUC_KR),
            displayName: "EUC-KR"
        ) {
            return (korean.encoding, korean.displayName)
        }

        if let western = evaluateWestern(
            data: probe,
            encoding: .windowsCP1252,
            displayName: "Windows-1252"
        ) {
            return (western.encoding, western.displayName)
        }

        return nil
    }

    /// 完整探测（小文件路径）。
    private static func detectFull(data: Data) -> EncodingDetectionResult {
        let probe = data.prefix(probeByteLimit)

        // 1. BOM
        if let bomResult = detectByBOM(data: data) {
            return bomResult
        }

        // 2. UTF-16 无 BOM 启发
        //
        // 必须早于 UTF-8 校验：纯 ASCII 文本编码成 UTF-16LE 后，
        // 字节流形如 `43 00 68 00 ...`，这是**合法的 UTF-8**（NUL 是合法码点），
        // 会被 UTF-8 校验直接接受，从而把每个字符间的 NUL 当成正文。
        if let utf16 = detectUTF16WithoutBOM(probe: probe, data: data) {
            return utf16
        }

        // 3. UTF-8 严格校验
        if let utf8Text = strictUTF8(data) {
            return EncodingDetectionResult(
                encoding: .utf8,
                displayName: "UTF-8",
                text: utf8Text,
                hasReplacementCharacters: false,
                isFallback: false
            )
        }

        // 4. CJK 候选互斥评分
        //
        // GB18030 几乎能解码任意字节流（它把大量字节序列映射到汉字），
        // 因此「能解码」不能作为判据，否则 Big5 / Shift-JIS 文本会被误判成 GB18030。
        // 这里对所有候选打分，取「目标文字占比最高」的那个。
        if let best = bestCJKCandidate(data: data) {
            return best
        }

        // 5. 韩文
        if let result = evaluateKorean(data: data, encoding: encoding(from: .EUC_KR), displayName: "EUC-KR") {
            return result
        }

        // 6. 西文
        if let result = evaluateWestern(data: data, encoding: .windowsCP1252, displayName: "Windows-1252") {
            return result
        }

        // 7. 兜底
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

    /// 严格 UTF-8 校验：解码成功、不含替换字符、不含 NUL。
    ///
    /// NUL 字节在纯文本里不应出现。若出现，多半是被 UTF-16 编码过的文本
    /// （每个 ASCII 字符后跟一个 0x00），此时应交给 UTF-16 分支处理。
    private static func strictUTF8(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return text
    }

    // MARK: - UTF-16 启发

    private static func detectUTF16WithoutBOM(probe: Data, data: Data) -> EncodingDetectionResult? {
        let bytes = [UInt8](probe)
        guard bytes.count >= 16, bytes.count % 2 == 0 else { return nil }

        var zeroAtEven = 0
        var zeroAtOdd = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            if index % 2 == 0 { zeroAtEven += 1 } else { zeroAtOdd += 1 }
        }

        let half = bytes.count / 2
        guard half > 0 else { return nil }
        let evenRatio = Double(zeroAtEven) / Double(half)
        let oddRatio = Double(zeroAtOdd) / Double(half)

        // 判据：某一侧的 0 字节密度显著高于另一侧，且另一侧几乎无 0。
        //
        // 阈值取 0.20 而非 0.30：换行符（0x000A）、空格（0x0020）
        // 等低字节也会贡献 0，实际密度通常在 0.3~0.5 之间；
        // 但短文本或含较多双字节字符时可能降到 0.2 出头。
        // 同时要求另一侧 < 0.02，确保方向明确。
        let encoding: String.Encoding
        let name: String
        if oddRatio > 0.20 && evenRatio < 0.02 {
            // ASCII 字符的高字节为 0，位于奇数位 → UTF-16LE
            encoding = .utf16LittleEndian
            name = "UTF-16 LE"
        } else if evenRatio > 0.20 && oddRatio < 0.02 {
            encoding = .utf16BigEndian
            name = "UTF-16 BE"
        } else {
            return nil
        }

        guard let text = String(data: data, encoding: encoding) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }

        // 二次校验：解出来的文本控制字符不能过多，
        // 否则可能是恰好含大量 0 字节的二进制文件。
        let sample = String(text.prefix(2048))
        let metrics = measure(sample)
        guard metrics.controlRatio < controlCharacterRatioLimit else { return nil }

        return EncodingDetectionResult(
            encoding: encoding,
            displayName: name,
            text: text,
            hasReplacementCharacters: false,
            isFallback: false
        )
    }

    // MARK: - CJK 互斥评分

    /// 候选编码及其目标文字类型。
    private struct CJKCandidate {
        var encoding: String.Encoding
        var displayName: String
        /// 该编码对应的目标文字。
        var script: Script
    }

    private enum Script {
        case han
        case kana
    }

    /// 对所有 CJK 候选打分，返回目标文字占比最高的一个。
    ///
    /// 为什么要打分而不是「按顺序取第一个能解码的」：
    /// GB18030 的字节空间几乎覆盖所有双字节序列，任何 Big5 / Shift-JIS 文本
    /// 都能被它「成功解码」成一堆生僻汉字。只有比较「解出来的东西有多像目标语言」，
    /// 才能区分真正的编码。
    private static func bestCJKCandidate(data: Data) -> EncodingDetectionResult? {
        let candidates: [CJKCandidate] = [
            CJKCandidate(encoding: encoding(from: .GB_18030_2000), displayName: "GB18030", script: .han),
            CJKCandidate(encoding: encoding(from: .GB_2312_80), displayName: "GBK", script: .han),
            CJKCandidate(encoding: encoding(from: .big5), displayName: "Big5", script: .han),
            CJKCandidate(encoding: encoding(from: .shiftJIS), displayName: "Shift-JIS", script: .kana),
            CJKCandidate(encoding: encoding(from: .EUC_JP), displayName: "EUC-JP", script: .kana),
        ]

        /// 单个候选的评分结果。
        struct Scored {
            var candidate: CJKCandidate
            var text: String
            var metrics: TextMetrics
        }

        var scored: [Scored] = []
        scored.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard let text = String(data: data, encoding: candidate.encoding) else { continue }
            guard !text.contains("\u{FFFD}") else { continue }

            let sample = String(text.prefix(4096))
            guard !sample.isEmpty else { continue }

            let metrics = measure(sample)
            guard metrics.controlRatio < controlCharacterRatioLimit else { continue }

            // 目标文字占比过低 → 该编码解出来的不是这种语言
            switch candidate.script {
            case .han:
                guard metrics.hanRatio > chineseCharacterRatioThreshold else { continue }
            case .kana:
                guard metrics.kanaRatio > kanaRatioThreshold else { continue }
            }

            scored.append(Scored(candidate: candidate, text: text, metrics: metrics))
        }

        guard !scored.isEmpty else { return nil }

        // 决策依据：字节级线索优先，字符统计兜底。
        //
        // Shift-JIS 的双字节高字节落在 0x81–0x9F（或 0xE0–0xEF），
        // 而 GB18030 / Big5 的双字节高字节落在 0xA1–0xFE。
        // 这是字节层面的互斥特征，比「解出来像不像中文」可靠得多，
        // 因为 GB18030 能把任何字节流解成看似合理的汉字。
        let hint = byteRangeHint(data: data)

        if hint == .shiftJIS {
            if let japanese = scored.first(where: { $0.candidate.encoding == encoding(from: .shiftJIS) }) {
                return EncodingDetectionResult(
                    encoding: japanese.candidate.encoding,
                    displayName: japanese.candidate.displayName,
                    text: japanese.text,
                    hasReplacementCharacters: false,
                    isFallback: false
                )
            }
        }

        // 假名密度足够高 → 日文（覆盖 EUC-JP 这类字节范围与中文重叠的编码）
        if hint != .doubleByteHigh {
            if let japanese = scored
                .filter({ $0.candidate.script == .kana })
                .max(by: { $0.metrics.kanaRatio < $1.metrics.kanaRatio }) {
                return EncodingDetectionResult(
                    encoding: japanese.candidate.encoding,
                    displayName: japanese.candidate.displayName,
                    text: japanese.text,
                    hasReplacementCharacters: false,
                    isFallback: false
                )
            }
        }

        // 中文候选：取汉字密度最高者
        guard let chinese = scored
            .filter({ $0.candidate.script == .han })
            .max(by: { $0.metrics.hanRatio < $1.metrics.hanRatio }) else {
            return nil
        }

        return EncodingDetectionResult(
            encoding: chinese.candidate.encoding,
            displayName: chinese.candidate.displayName,
            text: chinese.text,
            hasReplacementCharacters: false,
            isFallback: false
        )
    }

    /// 字节范围的粗分类。
    private enum ByteRangeHint {
        /// 双字节高字节主要落在 0x81–0x9F：Shift-JIS 特征。
        case shiftJIS
        /// 双字节高字节主要落在 0xA1–0xFE：GB18030 / Big5 特征。
        case doubleByteHigh
        /// 无明显倾向。
        case inconclusive
    }

    /// 统计双字节序列的高字节分布，给出编码倾向。
    private static func byteRangeHint(data: Data) -> ByteRangeHint {
        let bytes = [UInt8](data.prefix(probeByteLimit))
        guard bytes.count > 8 else { return .inconclusive }

        var low = 0   // 0x81...0x9F
        var high = 0  // 0xA1...0xFE
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                index += 1
                continue
            }
            // 双字节序列的首字节
            if (0x81...0x9F).contains(byte) {
                low += 1
            } else if (0xA1...0xFE).contains(byte) {
                high += 1
            }
            index += 2
        }

        let total = low + high
        guard total >= 8 else { return .inconclusive }

        let lowRatio = Double(low) / Double(total)
        let highRatio = Double(high) / Double(total)

        if lowRatio > 0.8 { return .shiftJIS }
        if highRatio > 0.8 { return .doubleByteHigh }
        return .inconclusive
    }

    /// 文本统计指标。
    private struct TextMetrics {
        var hanRatio: Double
        var kanaRatio: Double
        var hangulRatio: Double
        var controlRatio: Double
    }

    private static func measure(_ sample: String) -> TextMetrics {
        var han = 0
        var kana = 0
        var hangul = 0
        var control = 0

        for scalar in sample.unicodeScalars {
            let value = scalar.value

            // CJK 统一表意文字 + 扩展 A + 兼容表意文字
            if (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0xF900...0xFAFF).contains(value) {
                han += 1
            }
            // 平假名 + 片假名 + 半角片假名
            if (0x3040...0x30FF).contains(value) || (0xFF66...0xFF9D).contains(value) {
                kana += 1
            }
            // 谚文音节 + 字母
            if (0xAC00...0xD7AF).contains(value) || (0x1100...0x11FF).contains(value) {
                hangul += 1
            }
            // 除常见空白外的控制字符
            if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D {
                control += 1
            }
            if (0x7F...0x9F).contains(value) {
                control += 1
            }
        }

        let total = Double(sample.count)
        guard total > 0 else {
            return TextMetrics(hanRatio: 0, kanaRatio: 0, hangulRatio: 0, controlRatio: 1)
        }

        return TextMetrics(
            hanRatio: Double(han) / total,
            kanaRatio: Double(kana) / total,
            hangulRatio: Double(hangul) / total,
            controlRatio: Double(control) / total
        )
    }

    /// 韩文探测。
    private static func evaluateKorean(
        data: Data,
        encoding: String.Encoding,
        displayName: String
    ) -> EncodingDetectionResult? {
        guard let text = String(data: data, encoding: encoding) else { return nil }
        guard !text.contains("\u{FFFD}") else { return nil }

        let sample = String(text.prefix(4096))
        guard !sample.isEmpty else { return nil }

        let metrics = measure(sample)
        guard metrics.controlRatio < controlCharacterRatioLimit else { return nil }
        guard metrics.hangulRatio > 0.05 else { return nil }

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

        let metrics = measure(sample)
        guard metrics.controlRatio < controlCharacterRatioLimit else { return nil }

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
