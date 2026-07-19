//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// lab-controller 的命令列引數；所有旗標皆於行程啟動時注入，不讀任何設定檔。
/// 未給 `--version`／`--poll-interval` 時採用 `Config` 的預設值；未知旗標、缺值或格式
/// 不合法由 ArgumentParser 直接印出用法說明並結束行程（`parseOrExit()`／`parse(_:)`）。
/// 只借用 `ParsableCommand` 取得正確的 `--help` 用法名稱與解析機制；`run()` 不實作、
/// 行程生命週期（心跳／訊號處理）留在可執行檔目標，本型別維持純解析、全部可測。
public struct LabControllerCommand: ParsableCommand {

    public static let configuration: CommandConfiguration = .init(commandName: "lab-controller")

    /// GitLab API 版本；未給時回落 `Config.default.version`。
    @Option(help: "GitLab API version to target.")
    public var version: String = Config.default.version

    /// 兩次輪詢之間的間隔秒數；未給時回落 `Config.default.poll.intervalSeconds`。
    @Option(help: "Seconds between heartbeat ticks.")
    public var pollInterval: Int = Config.default.poll.intervalSeconds

    public init() {}

    /// 由已解析的旗標值組出 `Config`。
    public var resolvedConfig: Config {
        Config(version: version, poll: .init(intervalSeconds: pollInterval))
    }
}
