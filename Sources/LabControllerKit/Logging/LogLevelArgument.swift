//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Logging

/// `--log-level` 收得下的值——`Logging.Logger.Level` 的鏡像。
///
/// 不直接讓 `Logger.Level` 認 `ExpressibleByArgument`：型別與協定分屬兩個外部模組，補那份
/// 一致性得標 `@retroactive`、而且會讓所有引用這個模組的地方都吃到它。自家鏡像多十行，換來
/// `--help` 列出的順序由這裡定、也不動別人的型別。
public enum LogLevelArgument: String, CaseIterable, ExpressibleByArgument, Sendable {

    /// 逐步追蹤。
    case trace

    /// 除錯細節。
    case debug

    /// 預設門檻：值得留下的事件。
    case info

    /// 需要留意、但不影響進行。
    case notice

    /// 有異狀。
    case warning

    /// 操作失敗。
    case error

    /// 只留最嚴重的。
    case critical

    /// 對應的紀錄層級。
    public var level: Logger.Level {
        switch self {
        case .trace: .trace
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warning: .warning
        case .error: .error
        case .critical: .critical
        }
    }
}
