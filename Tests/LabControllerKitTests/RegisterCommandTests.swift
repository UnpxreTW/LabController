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

private final class RegisterCommandTests {

    /// 給齊 `--host` 與 `--registration-token` 時解析為 `register` 子命令、欄位對應正確。
    @Test
    func `register parses host and registration token`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(
            ["register", "--host", "https://gitlab.example.com", "--registration-token", "synthetic-registration"]
        )
        let register: RegisterCommand = try #require(parsed as? RegisterCommand)
        #expect(register.host == "https://gitlab.example.com")
        #expect(register.registrationToken == "synthetic-registration")
        #expect(register.description == nil)
    }

    /// `--description` 為可選欄；給了就帶入。
    @Test
    func `register accepts optional description`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot([
            "register",
            "--host", "https://gitlab.example.com",
            "--registration-token", "synthetic-registration",
            "--description", "synthetic runner",
        ])
        let register: RegisterCommand = try #require(parsed as? RegisterCommand)
        #expect(register.description == "synthetic runner")
    }

    /// 缺必填的 `--registration-token` 應拋錯。
    @Test
    func `register without registration token throws`() {
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parseAsRoot(["register", "--host", "https://gitlab.example.com"])
        }
    }

    /// 缺必填的 `--host` 應拋錯。
    @Test
    func `register without host throws`() {
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parseAsRoot(["register", "--registration-token", "synthetic-registration"])
        }
    }

    /// 掛上子命令後，根命令無引數的解析行為不變（回歸）。
    @Test
    func `root command without arguments still parses`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot([])
        #expect(parsed is LabControllerCommand)
    }
}
