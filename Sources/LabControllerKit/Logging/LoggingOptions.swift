//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import Logging

/// 每支子命令共用的紀錄門檻選項。
///
/// 解析只此一處：旗標優先於 `LOG_LEVEL` 環境變數，兩者都沒有就是 `info`。旗標宣告成 optional
/// 才分得出「沒給」與「給了跟預設一樣的值」，代價是 `--help` 不會自動印預設值 ⇒ 說明文字自己寫。
///
/// - Note: 套用寫在 ``apply(to:environment:)``、不寫在 `validate()`：本專案的可執行檔自己解析
///   完再分派子命令，套用擺在那個分派點，解析本身就不動任何行程狀態——同一顆已解析的命令拿去
///   測試時不會順手改掉整個行程的門檻。
public struct LoggingOptions: ParsableArguments {

    /// 紀錄門檻；未給就看 `LOG_LEVEL`。
    @Option(
        name: .customLong("log-level"),
        help: "Minimum log level (default: info, or the LOG_LEVEL environment variable)."
    )
    public var logLevel: LogLevelArgument?

    /// 供 ArgumentParser 建構。
    public init() {}

    /// 把解析結果套進紀錄門檻。
    ///
    /// - Parameters:
    ///   - threshold: 要寫進去的門檻；未給時是整個行程共用的那一份。
    ///   - environment: 行程環境；未給時讀真正的那一份。
    /// - Returns: 需要提醒操作者時的那句話，沒有就是 nil。
    public func apply(
        to threshold: LogLevelThreshold = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let resolved: (level: Logger.Level, warning: String?) = LoggingOptions.resolve(
            flag: logLevel,
            environment: environment
        )
        threshold.set(resolved.level)
        return resolved.warning
    }

    /// 由旗標與環境決定門檻——純函式，不讀行程狀態、不寫任何東西。
    ///
    /// 環境變數是備援、不是輸入驗證面：值不認得時不擲錯（那會讓一個打錯字的環境變數擋掉整支
    /// 命令），改落回 `info` 並回一句待送出的提醒。
    ///
    /// - Parameters:
    ///   - flag: `--log-level` 給的值；未給為 nil。
    ///   - environment: 行程環境。
    /// - Returns: 門檻，以及需要提醒時的那句話。
    public static func resolve(
        flag: LogLevelArgument?,
        environment: [String: String]
    ) -> (level: Logger.Level, warning: String?) {
        if let flag: LogLevelArgument {
            return (flag.level, nil)
        }
        guard
            let raw: String = environment[LoggingOptions.environmentKey],
            !raw.isEmpty
        else { return (.info, nil) }
        guard let parsed: LogLevelArgument = .init(rawValue: raw.lowercased()) else {
            let quoted: String = LoggingOptions.sanitize(raw)
            return (.info, "LOG_LEVEL=\(quoted) is not a log level; using info")
        }
        return (parsed.level, nil)
    }

    /// 備援門檻的環境變數名。
    private static let environmentKey: String = "LOG_LEVEL"

    /// 提醒句裡的環境變數值上限。
    private static let valueLimit: Int = 32

    /// 外來字串進紀錄行之前的消毒：非英數一律換成 `_`、過長截斷。
    ///
    /// 換行與 ESC 之類的字元原樣寫出去，會讓一個打錯的環境變數在落檔的紀錄裡看起來像另一行
    /// 合法紀錄。
    ///
    /// - Parameter value: 原值。
    /// - Returns: 可安全放進單行紀錄的字串。
    private static func sanitize(_ value: String) -> String {
        String(value.prefix(valueLimit).map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}
