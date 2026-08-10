//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Testing

private final class EventTypeRegistryTests {

    /// 公開發行版預設不認得任何型別——型別集合屬部署端規章。
    @Test
    func `the default registry is empty`() throws {
        #expect(EventTypeRegistry.empty.types.isEmpty)
        let type: EventType = try #require(.init(rawValue: "anything"))
        #expect(EventTypeRegistry.empty.definition(for: type) == nil)
    }

    /// 查得到的回定義、查不到的回 nil（查無屬正常路徑）。
    @Test
    func `looks up known types and reports unknown ones as nil`() throws {
        let known: EventType = try #require(.init(rawValue: "pipeline_failed"))
        let unknown: EventType = try #require(.init(rawValue: "pipeline_faild"))
        let registry: EventTypeRegistry = try .init(
            definitions: [.init(type: known, deduplication: .window(seconds: 300), summary: "pipeline 轉紅")]
        )
        #expect(registry.definition(for: known)?.deduplication == .window(seconds: 300))
        #expect(registry.definition(for: known)?.summary == "pipeline 轉紅")
        #expect(registry.definition(for: unknown) == nil)
    }

    /// 同型別重複定義不採「後者覆蓋」、直接拋錯。
    @Test
    func `rejects a duplicated type instead of letting one definition win`() throws {
        let type: EventType = try #require(.init(rawValue: "todo_pending"))
        #expect(throws: EventTypeRegistry.RegistryError.duplicateType(type)) {
            try EventTypeRegistry(
                definitions: [
                    .init(type: type, deduplication: .permanent),
                    .init(type: type, deduplication: .window(seconds: 60))
                ]
            )
        }
    }

    /// 自組態陣列解碼；順序保留、`summary` 可省。
    @Test
    func `decodes a definition array and keeps its order`() throws {
        let json: String = """
            [
              {"type":"first","deduplication":{"mode":"permanent"},"summary":"第一件"},
              {"type":"second","deduplication":{"mode":"window","seconds":90}}
            ]
            """
        let registry: EventTypeRegistry = try JSONDecoder().decode(EventTypeRegistry.self, from: .init(json.utf8))
        #expect(registry.types.map(\.rawValue) == ["first", "second"])
        let second: EventType = try #require(.init(rawValue: "second"))
        #expect(registry.definition(for: second)?.deduplication == .window(seconds: 90))
        #expect(registry.definition(for: second)?.summary == "")
    }

    /// 組態內型別重複時，解碼即失敗。
    @Test
    func `decoding rejects a duplicated type`() {
        let json: String = """
            [
              {"type":"dup","deduplication":{"mode":"permanent"}},
              {"type":"dup","deduplication":{"mode":"permanent"}}
            ]
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventTypeRegistry.self, from: .init(json.utf8))
        }
    }

    /// 定義裡的欄位名打錯不得靜默忽略。
    @Test
    func `decoding rejects an unknown definition field`() {
        let json: String = #"[{"type":"first","deduplication":{"mode":"permanent"},"summry":"打錯了"}]"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventTypeRegistry.self, from: .init(json.utf8))
        }
    }

    /// `summary` 明寫 `null` 與整欄不寫不是同一件事：前者失敗、後者視為空字串。
    @Test
    func `decoding rejects an explicitly null summary`() throws {
        let nulled: String = #"[{"type":"first","deduplication":{"mode":"permanent"},"summary":null}]"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventTypeRegistry.self, from: .init(nulled.utf8))
        }
        let omitted: String = #"[{"type":"first","deduplication":{"mode":"permanent"}}]"#
        let registry: EventTypeRegistry = try JSONDecoder().decode(
            EventTypeRegistry.self,
            from: .init(omitted.utf8)
        )
        let first: EventType = try #require(.init(rawValue: "first"))
        #expect(registry.definition(for: first)?.summary == "")
    }

    /// 重複型別的錯誤自己說得出人話——下游最順手的 `localizedDescription` 也要拿得到。
    @Test
    func `the duplicate type error describes itself`() throws {
        let type: EventType = try #require(.init(rawValue: "todo_pending"))
        let error: EventTypeRegistry.RegistryError = .duplicateType(type)
        #expect(error.description.contains("todo_pending"))
        #expect(error.localizedDescription == error.description)
    }

    /// 缺去重政策欄即失敗，不回落成某個預設政策。
    @Test
    func `decoding rejects a definition without a deduplication policy`() {
        let json: String = #"[{"type":"first"}]"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventTypeRegistry.self, from: .init(json.utf8))
        }
    }

    /// 編碼後解回同一張表。
    @Test
    func `round trips through json`() throws {
        let first: EventType = try #require(.init(rawValue: "first"))
        let second: EventType = try #require(.init(rawValue: "second"))
        let registry: EventTypeRegistry = try .init(
            definitions: [
                .init(type: first, deduplication: .permanent, summary: "第一件"),
                .init(type: second, deduplication: .window(seconds: 90))
            ]
        )
        let data: Data = try JSONEncoder().encode(registry)
        #expect(try JSONDecoder().decode(EventTypeRegistry.self, from: data) == registry)
    }
}
