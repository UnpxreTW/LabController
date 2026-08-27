//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

/// 每問一次就往前走一段的假時鐘。
///
/// 逾時要測的是「跑到一半超過上限」，而取系統時間的版本只能靠睡覺去逼近它——睡出來的測試
/// 既慢又會在忙碌的機器上偶爾翻紅。這裡改成問一次走一步，時間點因此完全確定。
final class SteppingClock: Sendable {

    /// 起點；固定值，測試不取系統時鐘。
    private let start: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 每問一次往前走多少秒。
    private let step: TimeInterval

    /// 已經被問過幾次。
    private let asked: Mutex<Int> = .init(0)

    /// 以步長建立。
    init(step: TimeInterval) {
        self.step = step
    }

    /// 交給 ``JobRunner`` 的取時刻方式。
    var now: @Sendable () -> Date {
        { [self] in tick() }
    }

    /// 回這一次的時刻，並把時鐘往前推一步。
    private func tick() -> Date {
        let count: Int = asked.withLock { value in
            defer { value += 1 }
            return value
        }
        return start.addingTimeInterval(step * .init(count))
    }
}
