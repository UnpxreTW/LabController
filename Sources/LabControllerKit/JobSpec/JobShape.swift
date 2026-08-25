//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一件工單的執行形狀：決定性腳本跑一趟，還是一個會來回讀改驗的迴圈。
///
/// 這不是「跑在哪」的分類（那歸執行後端），是「怎麼跑完」的分類——形狀決定工單要不要帶
/// 治理欄位（見 ``SessionGovernance``）：跑一趟的東西沒有回合可數，迴圈沒有上限會逛到天亮。
///
/// 兩種 session 分開列而不是共用一個「迴圈」值：**能不能寫 repo** 是結構性差異，唯讀的那種
/// 手上根本沒有可以推的憑證，寫成同一個值就得靠別處的欄位再分一次。
///
/// 蛇底 raw value 與 ``JobOutcome`` 同理——落在工單與結果檔裡、供非 Swift 的執行端讀。
public enum JobShape: String, Sendable, Equatable, Codable, CaseIterable {

    /// 決定性腳本跑一趟就結束：clone、跑命令、寫結果（rebase／build／test／lint）。
    case batch

    /// 迴圈，但不寫 repo：自己讀檔、查資料、產出裁決（llm-review）。
    case readOnlySession = "read_only_session"

    /// 迴圈且會寫 repo：讀檔、改檔、驗證、再改（issue 實作、CI 修復）。
    case developmentSession = "development_session"

    /// 是不是迴圈形狀——迴圈才需要治理欄位。
    public var isSession: Bool {
        switch self {
        case .batch: false
        case .readOnlySession, .developmentSession: true
        }
    }
}
