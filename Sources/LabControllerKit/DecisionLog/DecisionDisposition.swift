//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 決策引擎在一輪偵測裡對一則事件下的處置。
///
/// 這是封閉集合而非字串：處置種類是決策引擎的固定詞彙，封閉集合讓「日誌讀回時能不能對到
/// 已知處置」由型別擔保——來路不明的字串在解碼階段就會失敗，而不是靜靜落成一個沒有人處理
/// 的處置值。
///
/// raw value 用蛇底命名（`self_handled`）而非駝峰：日誌落在持久層、也會被非 Swift 的工具
/// （grep、jq、事後分析腳本）讀，蛇底是這類紀錄的通用寫法；改動 raw value 等於改動日誌格式，
/// 須連動 ``DecisionLogEntry/schemaVersion``。
public enum DecisionDisposition: String, Sendable, Equatable, Codable, CaseIterable {

    /// 只是偵測到、本輪未採取任何後續動作（尚在觀察或等待條件）。
    case detected

    /// 派成 pipeline／runner job 交由執行層處理。
    case dispatched

    /// 由 LabController 本體直接回寫站台處理掉（無程式碼執行的 orchestrator 動作）。
    case selfHandled = "self_handled"

    /// 本輪刻意不處理——去重命中、節流未到、或規章判定不需動作；原因記在 ``DecisionRecord/reason``。
    case skipped
}
