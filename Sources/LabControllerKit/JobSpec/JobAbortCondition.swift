//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 讓一件工單提早收手的那一條理由。
///
/// 值本身有用途，**但真正的用途在結果檔裡**（見 ``JobResult/stoppedAt``）：每次收手記下停在
/// 哪一條，才看得出哪一條真的在攔東西、哪一條從來沒響過。沒響過的是死規則、天天響的可能設
/// 太緊；不記就只能靠印象調參，而印象會被最近一次失敗綁架。
///
/// **前三條是卡住偵測器、不是成本上限**：機器時間不花錢，設它們是為了讓失控的迴圈有個盡頭，
/// 所以刻意設鬆；真正承重的是 ``noProgress`` 這種進度形的條件。
///
/// 蛇底 raw value 與 ``JobShape`` 同理——落在結果檔裡、供非 Swift 的執行端寫。
public enum JobAbortCondition: String, Sendable, Equatable, Codable, CaseIterable {

    /// 掛鐘時間用盡；同時也是「一格最久被佔多久」的上限。
    case wallClock = "wall_clock"

    /// 回合數用盡。
    case turnBudget = "turn_budget"

    /// LLM 呼叫次數用盡。
    case llmCallBudget = "llm_call_budget"

    /// 連續數個回合沒有新的**已驗證**進展。
    ///
    /// 「進展」一律取機器訊號、不採信自述：建置由紅轉綠、新的測試通過、檔案內容有淨變化且過得了
    /// 語法檢查。問對面「有沒有進展」永遠會得到有。
    case noProgress = "no_progress"

    /// 動過的檔案數超過上限、建置仍然沒綠。
    case filesChangedWithoutGreen = "files_changed_without_green"

    /// 試圖寫到 ``JobBoundary/allowedWrites`` 之外。
    ///
    /// **這條沒有門檻可調**：越界一次就停，而且是在寫入發生**之前**擋下——事後記一筆警告等於
    /// 已經寫出去了。
    case writeOutsideAllowList = "write_outside_allow_list"

    /// 名冊裡的模型接連給不出可用的輸出，降級鏈已經走完。
    ///
    /// 同樣沒有門檻可調：降級鏈的長度就是門檻。
    case modelInvalidOutput = "model_invalid_output"
}
