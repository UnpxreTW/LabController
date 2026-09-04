//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import LabControllerKit
import Logging
import Testing

/// 一組最小可解析的 `run` 引數；個別測試在後面追加要驗的旗標。
private let minimalRunArguments: [String] = [
    "run",
    "--host", "https://gitlab.example.invalid",
    "--token-file", "/secrets/runner-token",
    "--golden", "golden-xcode",
    "--os", "mac",
]

private final class LoggingOptionsTests {

    /// 兩處都沒說話就是 `info`。
    @Test
    func `neither flag nor environment falls back to info`() {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(flag: nil, environment: [:])
        #expect(resolved.level == .info)
        #expect(resolved.warning == nil)
    }

    /// 只有環境變數時照它。
    @Test
    func `environment sets the level`() {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
            flag: nil,
            environment: ["LOG_LEVEL": "debug"]
        )
        #expect(resolved.level == .debug)
        #expect(resolved.warning == nil)
    }

    /// 環境變數大小寫不計較——`LOG_LEVEL` 常常是人手打進 plist 或 shell 的。
    @Test
    func `environment value is case insensitive`() {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
            flag: nil,
            environment: ["LOG_LEVEL": "TRACE"]
        )
        #expect(resolved.level == .trace)
    }

    /// 旗標勝過環境變數。
    @Test
    func `flag wins over environment`() {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
            flag: .error,
            environment: ["LOG_LEVEL": "critical"]
        )
        #expect(resolved.level == .error)
        #expect(resolved.warning == nil)
    }

    /// 空字串等同沒設——`LOG_LEVEL=` 不該被當成打錯字。
    @Test
    func `empty environment value is treated as unset`() {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
            flag: nil,
            environment: ["LOG_LEVEL": ""]
        )
        #expect(resolved.level == .info)
        #expect(resolved.warning == nil)
    }

    /// 認不得的環境變數值不擲錯：落回 `info`、附一句提醒。
    @Test
    func `unknown environment value falls back to info with a warning`() {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
            flag: nil,
            environment: ["LOG_LEVEL": "verbose"]
        )
        #expect(resolved.level == .info)
        #expect(resolved.warning == "LOG_LEVEL=verbose is not a log level; using info")
    }

    /// 提醒句裡的外來值經消毒：換行與控制字元不得原樣進單行紀錄。
    @Test
    func `warning sanitises the offending value`() {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
            flag: nil,
            environment: ["LOG_LEVEL": "info\nerror lab-ctl: forged"]
        )
        #expect(resolved.level == .info)
        #expect(resolved.warning?.contains("\n") == false)
        #expect(resolved.warning == "LOG_LEVEL=info_error_lab_ctl__forged is not a log level; using info")
    }

    /// 過長的外來值截斷後才進提醒句，一個超長環境變數灌不出一行超長紀錄。
    @Test
    func `warning truncates an over long value`() {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
            flag: nil,
            environment: ["LOG_LEVEL": String(repeating: "a", count: 200)]
        )
        #expect(resolved.level == .info)
        #expect(resolved.warning == "LOG_LEVEL=\(String(repeating: "a", count: 32)) is not a log level; using info")
    }

    /// 每個可選值都對得上同名的 `Logger.Level`。
    @Test
    func `every argument value maps to the level of the same name`() {
        for argument in LogLevelArgument.allCases {
            #expect(argument.level.rawValue == argument.rawValue)
        }
    }

    /// 套用把解出來的門檻寫進拿到的那一份，回傳的提醒與 `resolve` 一致。
    @Test
    func `apply writes the resolved level into the given threshold`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(
            minimalRunArguments + ["--log-level", "trace"]
        )
        let run: RunCommand = try #require(parsed as? RunCommand)
        let threshold: LogLevelThreshold = .init()
        #expect(run.logging.apply(to: threshold, environment: ["LOG_LEVEL": "critical"]) == nil)
        #expect(threshold.level == .trace)
    }

    /// 旗標未給時套用落到環境變數上。
    @Test
    func `apply falls back to the environment when the flag is absent`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(minimalRunArguments)
        let run: RunCommand = try #require(parsed as? RunCommand)
        let threshold: LogLevelThreshold = .init()
        #expect(run.logging.apply(to: threshold, environment: ["LOG_LEVEL": "critical"]) == nil)
        #expect(threshold.level == .critical)
    }

    /// `run` 收得下 `--log-level`。
    @Test
    func `run accepts the log level flag`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(
            minimalRunArguments + ["--log-level", "critical"]
        )
        let run: RunCommand = try #require(parsed as? RunCommand)
        #expect(run.logging.logLevel == .critical)
    }

    /// `register` 收得下 `--log-level`。
    @Test
    func `register accepts the log level flag`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot([
            "register",
            "--host", "https://gitlab.example.invalid",
            "--registration-token", "token",
            "--log-level", "debug",
        ])
        let register: RegisterCommand = try #require(parsed as? RegisterCommand)
        #expect(register.logging.logLevel == .debug)
    }

    /// 根命令（心跳那條路）也收得下 `--log-level`。
    @Test
    func `the root command accepts the log level flag`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(["--log-level", "notice"])
        let root: LabControllerCommand = try #require(parsed as? LabControllerCommand)
        #expect(root.logging.logLevel == .notice)
    }

    /// 未給旗標時解析結果是 nil，`--help` 才不會多印一個沒人給過的值。
    @Test
    func `the flag is nil when not given`() throws {
        let parsed: any ParsableCommand = try LabControllerCommand.parseAsRoot(minimalRunArguments)
        let run: RunCommand = try #require(parsed as? RunCommand)
        #expect(run.logging.logLevel == nil)
    }

    /// 不認得的值在解析階段就被擋下。
    @Test
    func `an unknown flag value is rejected while parsing`() {
        #expect(throws: (any Error).self) {
            try LabControllerCommand.parseAsRoot(minimalRunArguments + ["--log-level", "verbose"])
        }
    }
}
