//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一件 job 在執行環境裡跑完之後的全部結果：怎麼收的、要不要讓站台重試、以及那份 trace。
///
/// **跑不成也回這個、不拋**：這一側的呼叫端拿到結果之後必定要回報給站台（trace 一段、終態
/// 一次），而拋出去的錯沒有 trace 也沒有失敗分類——接住它的人得自己再編一份，編出來的那份
/// 與實際發生的事情會慢慢對不上。真正該拋的是「連要回報什麼都算不出來」，而這裡不存在那種
/// 情況：環境開不起來就是 ``JobOutcome/systemFailed``。
///
/// ⚠️ ``trace`` **已過遮蔽**，可以往站台送；其餘欄位不含 payload 衍生字串。
public struct JobRunReport: Sendable, Equatable {

    /// 這次怎麼收的。
    public let outcome: JobOutcome

    /// 失敗分類；``JobOutcome/completed`` 時為 nil。
    ///
    /// 決定站台端要不要重試，故與 ``outcome`` 分開記：同樣是紅的，碼寫錯重跑幾次都一樣，
    /// 環境沒起來則多半下一次就好了。
    public let failureReason: JobFailureReason?

    /// 決定這次結果的那個結束碼。
    ///
    /// 失敗時是**第一個**失敗步驟的結束碼、不是最後一個：`after_script` 那類「不論如何都跑」
    /// 的步驟排在後面，拿最後一個等於把真正的死因換成收拾動作的結果。
    ///
    /// 完成時一律為 `0`——包含一個步驟都沒跑的 job：沒有任何命令失敗，這個數字說的就是這件事。
    /// **沒有任何結束碼決定得了結果時才是 nil**：檔案樹鋪不出來、後端送不進命令、或步驟一個都
    /// 還沒失敗就撞到時間上限。
    public let exitCode: Int32?

    /// 已遮蔽的完整 trace。
    public let trace: String

    /// 本次略過、但不影響結果正確性的能力宣告；原樣自 ``JobPlan/warnings`` 帶出。
    public let warnings: [UnsupportedJobFeature]

    /// 逐欄建立。
    public init(
        outcome: JobOutcome,
        failureReason: JobFailureReason? = nil,
        exitCode: Int32? = nil,
        trace: String = "",
        warnings: [UnsupportedJobFeature] = []
    ) {
        self.outcome = outcome
        self.failureReason = failureReason
        self.exitCode = exitCode
        self.trace = trace
        self.warnings = warnings
    }
}
