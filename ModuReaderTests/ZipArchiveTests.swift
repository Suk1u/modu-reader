//
//  ZipArchiveTests.swift
//  ModuReaderTests
//
//  ZIP 解析与解压测试。
//
//  重点覆盖 deflate：EPUB / CBZ 绝大多数条目都是 deflate，
//  而 Apple 的 compression_decode_buffer 无法处理 raw deflate，
//  必须用 libz 的 inflateInit2(-15)。这些用例锁住该实现。
//

import Testing
import Foundation
import zlib
@testable import ModuReader

@Suite("ZIP 解析")
struct ZipArchiveTests {

    // MARK: - 构造测试 ZIP

    /// 用 raw deflate 压缩数据。
    private static func deflate(_ data: Data) -> Data? {
        var stream = z_stream()
        var status = zlib.deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -15,                      // raw deflate
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { return nil }
        defer { zlib.deflateEnd(&stream) }

        // 先算好容量，避免在 withUnsafeMutableBytes 闭包里再读 output.count
        // （那会造成对 output 的独占访问冲突）
        let capacity = max(64, data.count + data.count / 2 + 64)
        var output = Data(count: capacity)

        let written: Int? = data.withUnsafeBytes { inputBuffer -> Int? in
            guard let inputPointer = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return nil
            }
            return output.withUnsafeMutableBytes { outputBuffer -> Int? in
                guard let outputPointer = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return nil
                }
                stream.next_in = UnsafeMutablePointer(mutating: inputPointer)
                stream.avail_in = uInt(data.count)
                stream.next_out = outputPointer
                stream.avail_out = uInt(capacity)
                status = zlib.deflate(&stream, Z_FINISH)
                guard status == Z_STREAM_END else { return nil }
                return Int(stream.total_out)
            }
        }
        guard let written else { return nil }
        return output.prefix(written)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 == 1) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// 构造 ZIP。`compress` 为 true 时用 deflate，false 时 store。
    private static func makeZip(
        files: [(path: String, content: Data)],
        compress: Bool
    ) -> Data {
        var output = Data()
        var central = Data()

        for file in files {
            let nameData = Data(file.path.utf8)
            let payload = compress ? (deflate(file.content) ?? file.content) : file.content
            let method: UInt16 = compress ? 8 : 0
            let crc = crc32(file.content)
            let offset = UInt32(output.count)

            var local = Data()
            local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            local.appendUInt16(20)
            local.appendUInt16(0)
            local.appendUInt16(method)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt32(crc)
            local.appendUInt32(UInt32(payload.count))
            local.appendUInt32(UInt32(file.content.count))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)
            local.append(nameData)
            local.append(payload)
            output.append(local)

            var entry = Data()
            entry.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            entry.appendUInt16(20)
            entry.appendUInt16(20)
            entry.appendUInt16(0)
            entry.appendUInt16(method)
            entry.appendUInt16(0)
            entry.appendUInt16(0)
            entry.appendUInt32(crc)
            entry.appendUInt32(UInt32(payload.count))
            entry.appendUInt32(UInt32(file.content.count))
            entry.appendUInt16(UInt16(nameData.count))
            entry.appendUInt16(0)
            entry.appendUInt16(0)
            entry.appendUInt16(0)
            entry.appendUInt16(0)
            entry.appendUInt32(0)
            entry.appendUInt32(offset)
            entry.append(nameData)
            central.append(entry)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        eocd.appendUInt16(0)
        eocd.appendUInt16(0)
        eocd.appendUInt16(UInt16(files.count))
        eocd.appendUInt16(UInt16(files.count))
        eocd.appendUInt32(UInt32(central.count))
        eocd.appendUInt32(centralOffset)
        eocd.appendUInt16(0)
        output.append(eocd)

        return output
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-\(UUID().uuidString).zip")
        try data.write(to: url)
        return url
    }

    // MARK: - Tests

    @Test("列出 store 模式条目")
    func listStoredEntries() throws {
        let content = Data("hello world".utf8)
        let zipData = Self.makeZip(files: [("a.txt", content)], compress: false)
        let url = try writeTemp(zipData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entries = try archive.entries()

        #expect(entries.count == 1)
        #expect(entries[0].path == "a.txt")
        #expect(entries[0].compressionMethod == 0)
        #expect(entries[0].uncompressedSize == content.count)
    }

    @Test("解压 store 模式数据")
    func readStoredData() throws {
        let content = Data("hello world".utf8)
        let zipData = Self.makeZip(files: [("a.txt", content)], compress: false)
        let url = try writeTemp(zipData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entry = try archive.entry(at: "a.txt")
        let data = try archive.data(for: entry)

        #expect(data == content)
    }

    @Test("解压 deflate 模式数据")
    func readDeflatedData() throws {
        // 用可压缩的重复内容，确保 deflate 真的压缩了
        let text = String(repeating: "这是一段用于测试 deflate 的中文内容。", count: 200)
        let content = Data(text.utf8)
        let zipData = Self.makeZip(files: [("b.txt", content)], compress: true)
        let url = try writeTemp(zipData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entry = try archive.entry(at: "b.txt")

        #expect(entry.compressionMethod == 8)
        // 确认确实压缩了
        #expect(entry.compressedSize < entry.uncompressedSize)

        let data = try archive.data(for: entry)
        #expect(data.count == content.count)
        #expect(data == content)
    }

    @Test("deflate 解压大文件")
    func readLargeDeflatedFile() throws {
        // 模拟字体文件：二进制 + 可压缩
        var content = Data()
        for index in 0..<50_000 {
            content.append(UInt8(index % 256))
        }
        let zipData = Self.makeZip(files: [("font.ttf", content)], compress: true)
        let url = try writeTemp(zipData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entry = try archive.entry(at: "font.ttf")
        let data = try archive.data(for: entry)

        #expect(data.count == content.count)
        #expect(data == content)
    }

    @Test("多条目混合 store 与 deflate")
    func mixedCompression() throws {
        let textContent = Data(String(repeating: "重复内容", count: 100).utf8)
        let binaryContent = Data((0..<1000).map { UInt8($0 % 256) })

        let zipData = Self.makeZip(
            files: [
                ("text.txt", textContent),
                ("binary.bin", binaryContent),
            ],
            compress: true
        )
        let url = try writeTemp(zipData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        #expect(try archive.entries().count == 2)
        #expect(try archive.data(for: archive.entry(at: "text.txt")) == textContent)
        #expect(try archive.data(for: archive.entry(at: "binary.bin")) == binaryContent)
    }

    @Test("条目不存在时抛错")
    func missingEntry() throws {
        let zipData = Self.makeZip(files: [("a.txt", Data("x".utf8))], compress: false)
        let url = try writeTemp(zipData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        #expect(throws: ZipError.self) {
            try archive.entry(at: "nope.txt")
        }
    }

    @Test("非 ZIP 文件抛错")
    func notAZip() throws {
        let url = try writeTemp(Data("this is not a zip".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ZipError.self) {
            _ = try ZipArchive(url: url).entries()
        }
    }

    @Test("空压缩包抛错")
    func emptyArchive() throws {
        let url = try writeTemp(Data())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ZipError.self) {
            _ = try ZipArchive(url: url)
        }
    }

    @Test("UTF-8 文件名正确解码")
    func utf8FileName() throws {
        let zipData = Self.makeZip(
            files: [("中文目录/文件名.txt", Data("content".utf8))],
            compress: true
        )
        let url = try writeTemp(zipData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entries = try archive.entries()
        #expect(entries[0].path == "中文目录/文件名.txt")
    }

    @Test("目录条目被标记")
    func directoryEntry() throws {
        let zipData = Self.makeZip(
            files: [
                ("folder/", Data()),
                ("folder/file.txt", Data("x".utf8)),
            ],
            compress: false
        )
        let url = try writeTemp(zipData)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZipArchive(url: url)
        let entries = try archive.entries()
        let folder = entries.first { $0.path == "folder/" }
        #expect(folder?.isDirectory == true)
    }
}

// MARK: - 辅助

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
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
