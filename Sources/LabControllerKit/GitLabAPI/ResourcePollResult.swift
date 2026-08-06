//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一輪輪詢的產物：讀到的資源、推進後的游標，以及本輪走到哪裡收尾。
///
/// 游標與資源一起回傳、而不是由輪詢器自己持有：輪詢器是無狀態的，**要不要接受這一輪**由呼叫端決定。
/// 事件寫進儲存層失敗時，呼叫端只要不保存新游標，下一輪就會重讀同一段——若游標的推進藏在輪詢器
/// 內部，那批事件就在「已讀過」與「未落地」之間永久消失。
public struct ResourcePollResult<Element: Sendable>: Sendable {

    /// 本輪讀到的資源，**通常**依 `updated_at` 由舊到新。
    ///
    /// 不是保證：站台是照 `updated_at` 升冪回的，但多頁走查橫跨數次請求，翻頁期間若有帶著較舊時間戳的
    /// 資源被插進來（匯入、專案搬移），跨頁交界處就可能不是遞增。需要嚴格順序的下游請自行排序。
    ///
    /// **可能含上一輪已見過的內容**——游標刻意保守（見 `UpdatedAfterCursor`），去重是下游的職責。
    public let elements: [Element]

    /// 推進後的游標。呼叫端確認本輪產物已落地後才應保存。
    public let cursor: UpdatedAfterCursor

    /// 本輪走到哪裡收尾。
    public let completion: PollCompletion

    /// 本輪用來封頂游標的時刻可不可信。
    ///
    /// 與 `completion` 分開，是因為**不可信的上限未必會擋住游標**：上限若落在未來（前置代理時鐘走快、
    /// 快取發出指向未來的 `Date`），游標照樣推得動、本輪照樣 `complete`——上限等於不存在，
    /// 卻沒有任何跡象。而那正是會漏資料的方向：本輪查詢快照之後才提交、時間戳卻更早的資源會沉到水位之下。
    /// 把它併進 `completion` 就永遠報不出來，因為那個列舉在游標動得了時不看這一項。
    ///
    /// 為 `false` 的兩種情況：回應沒有可解析的 `Date` 標頭（只能退回本機時鐘、無從查核），
    /// 或有標頭但與本機時鐘的差距超過**容差再加一個請求逾時**（預設 150 秒，見
    /// `ProjectResourcePoller.defaultClockSkewAllowance`）。兩者都代表**這一輪的上限不該被當成保護**。
    ///
    /// ⚠ 反過來**不保證上限落在過去**：差距在門檻之內但仍走在前面的時鐘（例如快 130 秒的前置代理）
    /// 會讓上限落到未來、等於沒有上限，而這個旗標仍為 `true`。它是粗篩，不是保證。
    ///
    /// ⚠ 它**不指認是誰的錯**：這個判定只知道兩個時鐘對不上，站台端與本機端都可能是原因，
    /// 兩邊都要查。也因此它不會讓本輪被判成 `PollCompletion.stalled`——本機時鐘偏掉時站台完全正常，
    /// 那不是「不會自己好」的狀態。
    public let capIsTrustworthy: Bool

    /// 以顯式欄位建立。
    public init(
        elements: [Element],
        cursor: UpdatedAfterCursor,
        completion: PollCompletion,
        capIsTrustworthy: Bool = true
    ) {
        self.elements = elements
        self.cursor = cursor
        self.completion = completion
        self.capIsTrustworthy = capIsTrustworthy
    }
}
