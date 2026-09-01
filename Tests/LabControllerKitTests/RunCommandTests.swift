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

/// 一組最小可解析的引數；個別測試在後面追加要驗的旗標。
private let minimalArguments: [String] = [
    "run",
    "--host", "https://gitlab.example.invalid",
    "--token-file", "/secrets/runner-token",
    "--golden", "golden-xcode",
    "--os", "mac",
]

private final class RunCommandTests {

    /// 給齊必填旗標時解析為 `run` 子命令，各欄對應正確、其餘欄取預設。
    @Test
    func `run parses the required options`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(minimalArguments)
        let run: RunCommand = try #require(parsed as? RunCommand)
        #expect(run.host == "https://gitlab.example.invalid")
        #expect(run.tokenFile == "/secrets/runner-token")
        #expect(run.golden == "golden-xcode")
        #expect(run.os == .mac)
        #expect(run.socket == nil)
        #expect(!run.once)
        #expect(run.image == .alias("golden-xcode"))
    }

    /// 資源旗標未給時回落 `NymphBackendConfiguration` 的預設值。
    @Test
    func `run falls back to the backend defaults`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(minimalArguments)
        let run: RunCommand = try #require(parsed as? RunCommand)
        #expect(run.backendConfiguration == .init(os: .mac))
    }

    /// 資源旗標給了就原樣帶進開 guest 的參數。
    @Test
    func `run carries the resource options into the backend configuration`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(minimalArguments + [
            "--cpus", "8", "--memory-gib", "16", "--readiness-timeout", "600", "--once",
        ])
        let run: RunCommand = try #require(parsed as? RunCommand)
        #expect(run.backendConfiguration == .init(os: .mac, cpus: 8, memoryGiB: 16, readinessTimeoutSeconds: 600))
        #expect(run.once)
    }

    /// `--socket` 給了就用給的；沒給時算出來的那個至少是條絕對路徑。
    @Test
    func `run resolves the socket path`() throws {
        let explicit: any ParsableCommand = try LabControllerCommand.parseAsRoot(
            minimalArguments + ["--socket", "/tmp/nymph.sock"]
        )
        #expect(try #require(explicit as? RunCommand).resolvedSocketPath == "/tmp/nymph.sock")
        let fallback: RunCommand = try #require(
            try LabControllerCommand.parseAsRoot(minimalArguments) as? RunCommand
        )
        #expect(fallback.resolvedSocketPath.hasPrefix("/"))
        #expect(fallback.resolvedSocketPath.hasSuffix("nymph.sock"))
    }

    /// `--os` 是必填、且只收 nymph 認得的兩種；猜一個預設值等於在同名別名上靜默選錯引擎。
    @Test
    func `run requires a guest kind it recognises`() {
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parseAsRoot([
                "run", "--host", "https://gitlab.example.invalid",
                "--token-file", "/secrets/runner-token", "--golden", "golden-xcode",
            ])
        }
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parseAsRoot([
                "run", "--host", "https://gitlab.example.invalid",
                "--token-file", "/secrets/runner-token", "--golden", "golden-xcode", "--os", "windows",
            ])
        }
    }

    /// runner 認證 token 只從檔案讀：沒有這條旗標，token 才不會留在行程表與 shell 歷史裡。
    @Test
    func `run has no option that takes the token itself`() {
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parseAsRoot(minimalArguments + ["--token", "synthetic-runner-token"])
        }
    }

    /// 掛上第二個子命令後，`register` 與根命令的解析行為不變（回歸）。
    @Test
    func `existing commands still parse`() throws {
        let register: any ParsableCommand = try LabControllerCommand.parseAsRoot(
            ["register", "--host", "https://gitlab.example.invalid", "--registration-token", "synthetic"]
        )
        #expect(register is RegisterCommand)
        #expect(try LabControllerCommand.parseAsRoot([]) is LabControllerCommand)
    }
}
