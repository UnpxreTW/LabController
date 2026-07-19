//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import LabControllerKit
import Testing

private final class LabControllerCommandTests {

    /// 未給任何引數時，回落 `Config` 文件化的預設值（version "v4"、輪詢間隔 60）。
    @Test
    func `no arguments falls back to documented defaults`() throws {
        let command: LabControllerCommand = try LabControllerCommand.parse([])
        #expect(command.resolvedConfig.version == "v4")
        #expect(command.resolvedConfig.poll.intervalSeconds == 60)
    }

    /// 給定 `--version`／`--poll-interval` 時，兩欄皆採用引數值。
    @Test
    func `given flags override both fields`() throws {
        let command: LabControllerCommand = try LabControllerCommand.parse(["--version", "v3", "--poll-interval", "15"])
        #expect(command.resolvedConfig.version == "v3")
        #expect(command.resolvedConfig.poll.intervalSeconds == 15)
    }

    /// 只給其中一個旗標時，另一欄仍回落預設值。
    @Test
    func `single flag overrides only that field`() throws {
        let command: LabControllerCommand = try LabControllerCommand.parse(["--version", "v2"])
        #expect(command.resolvedConfig.version == "v2")
        #expect(command.resolvedConfig.poll.intervalSeconds == 60)
    }

    /// 不認得的旗標應拋錯。
    @Test
    func `unknown argument throws`() {
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parse(["--bogus"])
        }
    }

    /// 旗標缺少後續值應拋錯。
    @Test
    func `flag missing its value throws`() {
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parse(["--poll-interval"])
        }
    }

    /// `--poll-interval` 給非整數值應拋錯。
    @Test
    func `non-integer poll interval throws`() {
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parse(["--poll-interval", "soon"])
        }
    }
}
