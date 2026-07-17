//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import LabControllerKit
import Testing

private final class LaunchArgumentsTests {

    /// 未給任何引數時，回落 `Config` 文件化的預設值（apiVersion "v4"、輪詢間隔 60）。
    @Test
    func `no arguments falls back to documented defaults`() throws {
        let config: Config = try parseLaunchArguments([])
        #expect(config.apiVersion == "v4")
        #expect(config.poll.intervalSeconds == 60)
    }

    /// 給定 `--api-version`／`--poll-interval` 時，兩欄皆採用引數值。
    @Test
    func `given flags override both fields`() throws {
        let config: Config = try parseLaunchArguments(["--api-version", "v3", "--poll-interval", "15"])
        #expect(config.apiVersion == "v3")
        #expect(config.poll.intervalSeconds == 15)
    }

    /// 只給其中一個旗標時，另一欄仍回落預設值。
    @Test
    func `single flag overrides only that field`() throws {
        let config: Config = try parseLaunchArguments(["--api-version", "v2"])
        #expect(config.apiVersion == "v2")
        #expect(config.poll.intervalSeconds == 60)
    }

    /// 不認得的旗標應拋出 `unknownArgument`。
    @Test
    func `unknown argument throws`() {
        #expect(throws: LaunchArgumentError.unknownArgument("--bogus")) {
            try parseLaunchArguments(["--bogus"])
        }
    }

    /// 旗標缺少後續值應拋出 `missingValue`。
    @Test
    func `flag missing its value throws`() {
        #expect(throws: LaunchArgumentError.missingValue("--poll-interval")) {
            try parseLaunchArguments(["--poll-interval"])
        }
    }

    /// `--poll-interval` 給非整數值應拋出 `invalidValue`。
    @Test
    func `non-integer poll interval throws`() {
        #expect(throws: LaunchArgumentError.invalidValue(flag: "--poll-interval", value: "soon")) {
            try parseLaunchArguments(["--poll-interval", "soon"])
        }
    }
}
