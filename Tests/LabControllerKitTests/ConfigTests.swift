//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import LabControllerKit
import Testing
import Yams

private final class ConfigTests {

    /// 未給任何欄位時，`Config.default` 與 `Config()` 皆回落 apiVersion "v4"、輪詢間隔 60。
    @Test
    func `default config uses documented fallback values`() {
        let byStatic: Config = .default
        #expect(byStatic.apiVersion == "v4")
        #expect(byStatic.poll.intervalSeconds == 60)
        let byInit: Config = .init()
        #expect(byInit.apiVersion == "v4")
        #expect(byInit.poll.intervalSeconds == 60)
    }

    /// 完整 YAML 應逐欄解出對應值。
    @Test
    func `full yaml decodes every field`() throws {
        let yaml: String = """
        apiVersion: v3
        poll:
          intervalSeconds: 15
        """
        let config: Config = try YAMLDecoder().decode(Config.self, from: yaml)
        #expect(config.apiVersion == "v3")
        #expect(config.poll.intervalSeconds == 15)
    }

    /// 空 YAML（空 mapping、無任何鍵）應整份回落預設值。
    @Test
    func `empty yaml falls back to defaults`() throws {
        let config: Config = try YAMLDecoder().decode(Config.self, from: "{}")
        #expect(config.apiVersion == "v4")
        #expect(config.poll.intervalSeconds == 60)
    }

    /// 部分 YAML（僅 apiVersion）應保留給定值、缺欄回落預設。
    @Test
    func `partial yaml keeps given field and defaults the rest`() throws {
        let config: Config = try YAMLDecoder().decode(Config.self, from: "apiVersion: v2")
        #expect(config.apiVersion == "v2")
        #expect(config.poll.intervalSeconds == 60)
    }

    /// encode 後再 decode 應還原同值（round-trip）。
    @Test
    func `encode then decode round-trips values`() throws {
        let original: Config = .init(apiVersion: "v4", poll: .init(intervalSeconds: 42))
        let encoded: String = try YAMLEncoder().encode(original)
        let restored: Config = try YAMLDecoder().decode(Config.self, from: encoded)
        #expect(restored.apiVersion == "v4")
        #expect(restored.poll.intervalSeconds == 42)
    }
}
