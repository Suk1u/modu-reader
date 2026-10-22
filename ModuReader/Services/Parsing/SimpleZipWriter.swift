//
//  SimpleZipWriter.swift
//  ModuReader
//
//  最简 ZIP 写入器。只支持 store 模式（不压缩）。
//
//  用途：把 TXT 切分出的章节打包成标准 EPUB，交给 Readium 渲染。
//  为什么不压缩：EPUB 的 mimetype 条目按规范必须不压缩；
//  其余条目用 store 也能被所有阅读器接受，且省掉压缩实现。
//

import Foundation

/// 最简 ZIP 写入器。
enum SimpleZipWriter {

    /// 一个待写入的条目。
    struct Entry {
        var path: String
        var data: Data
    }

    /// 写入 ZIP 文件。
    ///
    /// - Parameters:
    ///   - entries: 条目列表，按写入顺序排列。`mimetype` 必须放在第一个。
    ///   - url: 输出路径。
    static func write(entries: [Entry], to url: URL) throws {
        var output = Data()
        var central = Data()

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(output.count)
            let size = UInt32(entry.data.count)

            // ---- 本地文件头 ----
            var local = Data()
            local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])  // 签名
            local.appendUInt16(20)                              // 解压所需版本
            local.appendUInt16(0x0800)                          // 通用标志：UTF-8 文件名
            local.appendUInt16(0)                               // 压缩方法：store
            local.appendUInt16(0)                               // 修改时间
            local.appendUInt16(0)                               // 修改日期
            local.appendUInt32(crc)
            local.appendUInt32(size)                            // 压缩后大小
            local.appendUInt32(size)                            // 原始大小
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)                               // 扩展字段长度
            local.append(nameData)
            local.append(entry.data)
            output.append(local)

            // ---- 中央目录条目 ----
            var record = Data()
            record.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            record.appendUInt16(20)                             // 创建版本
            record.appendUInt16(20)                             // 解压所需版本
            record.appendUInt16(0x0800)                         // 通用标志
            record.appendUInt16(0)                              // 压缩方法
            record.appendUInt16(0)                              // 修改时间
            record.appendUInt16(0)                              // 修改日期
            record.appendUInt32(crc)
            record.appendUInt32(size)
            record.appendUInt32(size)
            record.appendUInt16(UInt16(nameData.count))
            record.appendUInt16(0)                              // 扩展字段
            record.appendUInt16(0)                              // 注释
            record.appendUInt16(0)                              // 起始磁盘
            record.appendUInt16(0)                              // 内部属性
            record.appendUInt32(0)                              // 外部属性
            record.appendUInt32(offset)
            record.append(nameData)
            central.append(record)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)

        // ---- EOCD ----
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        eocd.appendUInt16(0)
        eocd.appendUInt16(0)
        eocd.appendUInt16(UInt16(entries.count))
        eocd.appendUInt16(UInt16(entries.count))
        eocd.appendUInt32(UInt32(central.count))
        eocd.appendUInt32(centralOffset)
        eocd.appendUInt16(0)
        output.append(eocd)

        try output.write(to: url, options: .atomic)
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1
                    ? (value >> 1) ^ 0xEDB88320
                    : value >> 1
            }
            return value
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - 小端写入

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
        ])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}