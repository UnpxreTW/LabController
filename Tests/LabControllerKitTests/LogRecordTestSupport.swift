//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Logging

/// 從兩份平行收集的紀錄裡取出某一個等級的那幾行。
///
/// 收行的出口一次交出等級與內容兩樣，而測試要斷言的是「這個等級寫了哪幾行」；兩份各自收在自己
/// 的鎖裡，在這裡才對起來。
///
/// - Parameters:
///   - level: 要取哪一個等級。
///   - levels: 依序收下的等級；由呼叫端先自鎖裡取出。
///   - lines: 依序收下的內容；同上。
/// - Returns: 該等級的那幾行，順序同寫出時。
internal func messages(at level: Logger.Level, levels: [Logger.Level], lines: [String]) -> [String] {
	zip(levels, lines).filter { $0.0 == level }.map(\.1)
}
