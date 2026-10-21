//
//  ModelContainer+Modu.swift
//  ModuReader
//

import Foundation
import SwiftData

enum ModuModelContainer {

    /// 全部 SwiftData 模型。
    static let schema = Schema([
        BookEntity.self,
        ProgressEntity.self,
    ])

    /// 应用使用的容器。
    ///
    /// 若持久化存储损坏（如迁移失败），回退到内存容器，
    /// 避免用户一启动就崩溃。
    static func make() -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            assertionFailure("SwiftData 容器创建失败：\(error)")
            let fallback = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            // 内存容器几乎不会失败；若仍失败，说明 schema 本身有问题。
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("无法创建内存 ModelContainer：\(error)")
            }
        }
    }

    /// 测试用的内存容器。
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
