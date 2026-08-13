//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// guest 執行完一件 job 後自評的結果類別，對齊 `result.json` 的 `status` 欄與 runner 的
/// exit code 三態語義。
///
/// **這是 guest 的自述、不是終審**：guest 依 job 的 `done_when` 自評落在哪一類，host 收回後
/// 仍會以站台終態二次核對（見 ``HostVerificationResult``）。兩者分開記，事後才查得出
/// 「guest 說完成、站台卻沒動」這種形狀。
///
/// 蛇底 raw value 與 ``DecisionDisposition`` 同理——落在持久層、供非 Swift 工具讀；改動即改
/// 動日誌格式，須連動 ``DecisionLogEntry/schemaVersion``。
public enum JobOutcome: String, Sendable, Equatable, Codable, CaseIterable {

    /// 依 `done_when` 判定完成。
    case completed

    /// job 本身失敗（碼錯、測試紅）——對齊 exit 1，不重試（重跑結果一樣）。
    case jobFailed = "job_failed"

    /// 系統層失敗（provision 失敗、result.json 缺失或 schema 不符）——對齊 exit 2，可重試。
    case systemFailed = "system_failed"

    /// 逾越 job 逾時上限被收掉。
    case timeout
}
