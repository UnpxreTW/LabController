//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Logging
import Synchronization

/// 一個行程共用的紀錄門檻。
///
/// 門檻要能在紀錄後端裝好之後才改：後端只能裝一次、且得在第一行紀錄送出之前，而門檻要等
/// 引數解析完才知道，兩件事的時序拆不到同一刻。把門檻放在這顆共享的參照上，後端每次都回讀
/// 它，於是改在什麼時候都算數。
///
/// 領件迴圈是多執行緒的 ⇒ 值上鎖。
public final class LogLevelThreshold: Sendable {

    /// 這個行程實際在用的那一份。
    public static let shared: LogLevelThreshold = .init()

    /// 門檻本體；預設 `info`。
    private let value: Mutex<Logger.Level> = .init(.info)

    /// 造一份獨立的門檻；測試用得上，行程本身走 ``shared``。
    public init() {}

    /// 目前的門檻。
    public var level: Logger.Level {
        value.withLock { $0 }
    }

    /// 換掉門檻。低於新門檻的紀錄自此不再送出。
    ///
    /// - Parameter level: 新門檻。
    public func set(_ level: Logger.Level) {
        value.withLock { $0 = level }
    }
}
