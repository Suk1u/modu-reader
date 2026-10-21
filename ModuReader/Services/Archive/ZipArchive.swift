//
//  ZipArchive.swift
//  ModuReader
//
//  只读 ZIP 解析器。EPUB 与 CBZ 共用。
//
//  为什么自己实现而不引入 ZIPFoundation：
//  - 只需要「列条目 + 按名取数据」两个能力，ZIPFoundation 的功能远超需求
//  - 零依赖能让 CI 构建更快、失败面更小
//  - EPUB / CBZ 的 ZIP 特性很简单（store / deflate，无加密）
//
//  实现依据：PKWARE APPNOTE 6.3.10 的中央目录结构。
//

import Foundation
import Compression

/// ZIP 条目。
struct ZipEntry: Hashable, Sendable {
    /// 条目在压缩包内的路径（已做编码修正）。
    var path: String
    /// 未压缩大小。
    var uncompressedSize: Int
    /// 压缩后大小。
    var compressedSize: Int
    /// 压缩方法：0 = store，8 = deflate。
    var compressionMethod: UInt16
    /// 本地文件头在文件中的偏移。
    var localHeaderOffset: UInt64
    /// 是否为目录。
    var isDirectory: Bool
    /// CRC32 校验值。
    var crc32: UInt32

    var fileExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    var fileName: String {
        (path as NSString).lastPathComponent
    }
}

/// ZIP 读取错误。
enum ZipError: LocalizedError {
    case notAZipFile
    case corruptedCentralDirectory
    case entryNotFound(String)
    case unsupportedCompression(UInt16)
    case decompressionFailed(String)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .notAZipFile:
            "不是有效的 ZIP 文件。"
        case .corruptedCentralDirectory:
            "ZIP 中央目录损坏，文件可能未下载完整。"
        case .entryNotFound(let path):
            "压缩包内找不到「\(path)」。"
        case .unsupportedCompression(let method):
            "不支持的压缩方式（\(method)）。仅支持 store 与 deflate。"
        case .decompressionFailed(let path):
            "解压「\(path)」失败。"
        case .fileTooLarge:
            "压缩包过大，超出处理上限。"
        }
    }
}

/// 只读 ZIP 解析器。
///
/// 使用方式：
/// ```swift
/// let archive = try ZipArchive(url: url)
/// let entries = try archive.entries()
/// let data = try archive.data(for: entry)
/// ```
///
/// 线程约束：实例不可跨线程共享。每次使用创建新实例。
final class ZipArchive {

    /// 解压后的单条目大小上限，防 zip bomb。
    static let maxEntrySize = 256 * 1024 * 1024
    /// 压缩包总大小上限。
    static let maxArchiveSize: UInt64 = 4 * 1024 * 1024 * 1024

    private let fileHandle: FileHandle
    private let fileSize: UInt64
    private var cachedEntries: [ZipEntry]?

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= Self.maxArchiveSize else {
            throw ZipError.fileTooLarge
        }
        guard size > 22 else {
            throw ZipError.notAZipFile
        }

        self.fileHandle = try FileHandle(forReadingFrom: url)
        self.fileSize = size
    }

    deinit {
        try? fileHandle.close()
    }

    // MARK: - Entries

    /// 列出全部条目。
    func entries() throws -> [ZipEntry] {
        if let cachedEntries {
            return cachedEntries
        }

        let centralDirectory = try locateCentralDirectory()
        let entries = try parseCentralDirectory(
            offset: centralDirectory.offset,
            size: centralDirectory.size,
            entryCount: centralDirectory.entryCount
        )
        cachedEntries = entries
        return entries
    }

    /// 按路径取条目。
    func entry(at path: String) throws -> ZipEntry {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let match = try entries().first(where: { $0.path == normalized }) else {
            throw ZipError.entryNotFound(path)
        }
        return match
    }

    /// 读取条目解压后的数据。
    func data(for entry: ZipEntry) throws -> Data {
        guard entry.uncompressedSize <= Self.maxEntrySize else {
            throw ZipError.fileTooLarge
        }
        guard !entry.isDirectory else { return Data() }

        let localHeader = try readLocalHeader(at: entry.localHeaderOffset)

        // 数据区起点 = 本地头偏移 + 30 + 文件名长度 + 扩展字段长度
        let dataOffset = entry.localHeaderOffset
            + UInt64(30)
            + UInt64(localHeader.fileNameLength)
            + UInt64(localHeader.extraFieldLength)

        guard dataOffset + UInt64(entry.compressedSize) <= fileSize else {
            throw ZipError.corruptedCentralDirectory
        }

        try fileHandle.seek(toOffset: dataOffset)
        guard let compressed = try fileHandle.read(upToCount: entry.compressedSize) else {
            throw ZipError.corruptedCentralDirectory
        }
        guard compressed.count == entry.compressedSize else {
            throw ZipError.corruptedCentralDirectory
        }

        switch entry.compressionMethod {
        case 0:
            return compressed

        case 8:
            guard let inflated = Self.inflate(
                compressed,
                expectedSize: entry.uncompressedSize
            ) else {
                throw ZipError.decompressionFailed(entry.path)
            }
            return inflated

        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    // MARK: - Central directory

    private struct CentralDirectoryLocation {
        var offset: UInt64
        var size: UInt64
        var entryCount: Int
    }

    /// 从文件尾部倒查 EOCD（End of Central Directory）记录。
    private func locateCentralDirectory() throws -> CentralDirectoryLocation {
        // EOCD 固定 22 字节 + 最多 65535 字节注释
        let maxSearch = min(UInt64(65_557), fileSize)
        let searchStart = fileSize - maxSearch

        try fileHandle.seek(toOffset: searchStart)
        guard let tail = try fileHandle.read(upToCount: Int(maxSearch)) else {
            throw ZipError.notAZipFile
        }

        // EOCD 签名：0x06054b50
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard let index = Self.lastIndex(of: signature, in: tail) else {
            throw ZipError.notAZipFile
        }

        let eocd = tail.subdata(in: index..<(index + 22))
        guard eocd.count >= 22 else {
            throw ZipError.corruptedCentralDirectory
        }

        let entryCount = Int(eocd.readUInt16(at: 10))
        let cdSize = UInt64(eocd.readUInt32(at: 12))
        let cdOffset = UInt64(eocd.readUInt32(at: 16))

        guard cdOffset + cdSize <= fileSize else {
            throw ZipError.corruptedCentralDirectory
        }

        return CentralDirectoryLocation(
            offset: cdOffset,
            size: cdSize,
            entryCount: entryCount
        )
    }

    private func parseCentralDirectory(
        offset: UInt64,
        size: UInt64,
        entryCount: Int
    ) throws -> [ZipEntry] {
        try fileHandle.seek(toOffset: offset)
        guard let data = try fileHandle.read(upToCount: Int(size)) else {
            throw ZipError.corruptedCentralDirectory
        }
        guard data.count >= 46 else {
            throw ZipError.corruptedCentralDirectory
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0

        while cursor + 46 <= data.count {
            // 中央目录条目签名：0x02014b50
            let signature = data.readUInt32(at: cursor)
            guard signature == 0x02014B50 else { break }

            let compressionMethod = data.readUInt16(at: cursor + 10)
            let crc32 = data.readUInt32(at: cursor + 16)
            let compressedSize = Int(data.readUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readUInt32(at: cursor + 24))
            let fileNameLength = Int(data.readUInt16(at: cursor + 28))
            let extraFieldLength = Int(data.readUInt16(at: cursor + 30))
            let commentLength = Int(data.readUInt16(at: cursor + 32))
            let externalAttributes = data.readUInt32(at: cursor + 38)
            let localHeaderOffset = UInt64(data.readUInt32(at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= data.count else { break }

            let nameData = data.subdata(in: nameStart..<nameEnd)
            let path = Self.decodeFileName(nameData)

            // Unix 模式下，目录标志在 external attributes 的高位
            let isDirectory = path.hasSuffix("/")
                || (externalAttributes & 0x10) != 0

            entries.append(
                ZipEntry(
                    path: path,
                    uncompressedSize: uncompressedSize,
                    compressedSize: compressedSize,
                    compressionMethod: compressionMethod,
                    localHeaderOffset: localHeaderOffset,
                    isDirectory: isDirectory,
                    crc32: crc32
                )
            )

            cursor = nameEnd + extraFieldLength + commentLength
        }

        guard !entries.isEmpty else {
            throw ZipError.corruptedCentralDirectory
        }
        return entries
    }

    // MARK: - Local header

    private struct LocalHeader {
        var fileNameLength: Int
        var extraFieldLength: Int
    }

    private func readLocalHeader(at offset: UInt64) throws -> LocalHeader {
        try fileHandle.seek(toOffset: offset)
        guard let header = try fileHandle.read(upToCount: 30), header.count >= 30 else {
            throw ZipError.corruptedCentralDirectory
        }
        // 本地文件头签名：0x04034b50
        guard header.readUInt32(at: 0) == 0x04034B50 else {
            throw ZipError.corruptedCentralDirectory
        }
        return LocalHeader(
            fileNameLength: Int(header.readUInt16(at: 26)),
            extraFieldLength: Int(header.readUInt16(at: 28))
        )
    }

    // MARK: - File name decoding

    /// 解码 ZIP 内的文件名。
    ///
    /// ZIP 规范用通用标志位 bit 11 表示文件名是否为 UTF-8。
    /// 但大量国产压缩工具不设该标志，文件名是 GBK。
    /// 这里先尝试 UTF-8，失败则回退 GB18030。
    private static func decodeFileName(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gb18030 = TextEncodingDetector.encoding(from: .GB_18030_2000)
        if let gb = String(data: data, encoding: gb18030) {
            return gb
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Inflate

    /// 解压 ZIP 的 deflate 数据。
    ///
    /// ZIP 存储的是 **raw deflate**（无 zlib 头），而
    /// `compression_decode_buffer` 只接受 **zlib 格式**（含 2 字节头 + 4 字节校验）。
    /// 因此需要手动加一个 zlib 头再解压。
    ///
    /// zlib 头格式（RFC 1950）：
    ///   CMF = 0x78（deflate, 32K window）
    ///   FLG = 0x01 / 0x9C / 0xDA（取决于压缩等级，这里用 0x9C 表示默认）
    /// 两者组合需满足 (CMF * 256 + FLG) % 31 == 0。
    /// 0x78 0x9C → 30876 % 31 == 0 ✓
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }

        var zlibData = Data([0x78, 0x9C])
        zlibData.append(data)
        // 追加 Adler-32 占位（部分实现要求完整流，末尾 4 字节）
        zlibData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { outputBuffer in
            guard let outputPointer = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return zlibData.withUnsafeBytes { inputBuffer -> Int in
                guard let inputPointer = inputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    outputPointer,
                    expectedSize,
                    inputPointer,
                    zlibData.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // MARK: - Byte helpers

    private static func lastIndex(of pattern: [UInt8], in data: Data) -> Int? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let bytes = [UInt8](data)
        var index = bytes.count - pattern.count
        while index >= 0 {
            if Array(bytes[index..<(index + pattern.count)]) == pattern {
                return index
            }
            index -= 1
        }
        return nil
    }
}

// MARK: - Data 读取辅助

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self)
            return UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
        }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self)
            return UInt32(base[offset])
                | (UInt32(base[offset + 1]) << 8)
                | (UInt32(base[offset + 2]) << 16)
                | (UInt32(base[offset + 3]) << 24)
        }
    }
}
