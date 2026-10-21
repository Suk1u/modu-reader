//
//  Diagnostics.swift
//  ModuReader
//
//  轻量诊断日志。
//
//  为什么需要：导入链路涉及 picker 回调、security scope、文件复制、
//  后台解析多个环节，任一环静默失败都会表现为「点了没反应」。
//  这里把关键节点写进日志，用户可在「设置 → 诊断日志」里查看并反馈。
//

import Foundation
import os

enum Diagnostics {

    private static let logger = Logger(subsystem: "com.modu.reader", category: "diagnostics")

    /// 内存中的最近日志（供界面展示）。
    private static let lock = NSLock()
    private nonisolated(unsafe) static var buffer: [String] = []
    private static let bufferLimit = 300

    /// 写入一条日志。
    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let timestamp = Self.formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"

        logger.info("\(entry, privacy: .public)")

        lock.lock()
        buffer.append(entry)
        if buffer.count > bufferLimit {
            buffer.removeFirst(buffer.count - bufferLimit)
        }
        lock.unlock()
    }

    /// 读取全部日志。
    static func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// 清空日志。
    static func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
