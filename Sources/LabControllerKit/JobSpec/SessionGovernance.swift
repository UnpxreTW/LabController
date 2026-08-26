//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 迴圈形工單的治理欄位：跑多久算久、什麼時候該收手、可以用哪些模型。
///
/// 只有迴圈需要這一份（見 ``JobShape/isSession``）——跑一趟的腳本沒有回合可數，硬給它一份
/// 門檻只會多出一組永遠不會被讀的數字。
///
/// ⚠ **本型別不提供任何預設值、也不該有**：門檻要調就得改設定、不該改碼重新部署；而目前的
/// 各組值全部是 placeholder，尚未經實際跑動的數據校正過，**在回填之前不得被當成已校正的門檻
/// 引用**。給了預設值，那些未校正的數字就會安靜地變成事實上的標準。
public struct SessionGovernance: Sendable, Equatable, Codable {

    /// 預算：三個一起用完才算把迴圈的盡頭圍起來。
    ///
    /// **這是卡住偵測器、不是成本上限**——機器時間不花錢，所以刻意設鬆：它要攔的是失控，
    /// 不是浪費。真正該先響的是 ``AbortConditions`` 那組進度形的條件。
    public struct Budget: Sendable, Equatable, Codable {

        /// 掛鐘上限（秒）。
        public let wallClockSeconds: Int

        /// 回合數上限；一回合＝一次 LLM 呼叫加上它引起的工具動作。
        public let turns: Int

        /// LLM 呼叫次數上限（含重試）。
        public let llmCalls: Int

        /// 以顯式欄位建立。
        public init(wallClockSeconds: Int, turns: Int, llmCalls: Int) {
            self.wallClockSeconds = wallClockSeconds
            self.turns = turns
            self.llmCalls = llmCalls
        }
    }

    /// 進度形的收手條件：真正承重的那組。
    ///
    /// 只放**有門檻可調**的兩條。越界寫入與模型無效輸出同樣會讓迴圈收手，但它們沒有可調的
    /// 數字（見 ``JobAbortCondition/writeOutsideAllowList``），放進來只會多出兩個看起來可以
    /// 放寬、其實不能放寬的欄位。
    public struct AbortConditions: Sendable, Equatable, Codable {

        /// 連續幾個回合沒有已驗證的進展就收手。
        public let noProgressTurns: Int

        /// 動過幾個檔案而建置仍未轉綠就收手。
        public let filesChangedWithoutGreen: Int

        /// 以顯式欄位建立。
        public init(noProgressTurns: Int, filesChangedWithoutGreen: Int) {
            self.noProgressTurns = noProgressTurns
            self.filesChangedWithoutGreen = filesChangedWithoutGreen
        }
    }

    /// 本次的預算。
    public let budget: Budget

    /// 本次的進度形收手條件。
    public let abortConditions: AbortConditions

    /// 本次可用的模型，**順序即降級鏈**：前面的先用，給不出可用輸出才換下一個。
    ///
    /// 名冊隨工單帶、不由執行端自己挑：換模型是會影響結果的決定，決定要留在派工這一側才追得回
    /// 「那一局是誰跑的」。
    public let modelRoster: [String]

    /// 以顯式欄位建立。
    public init(budget: Budget, abortConditions: AbortConditions, modelRoster: [String]) {
        self.budget = budget
        self.abortConditions = abortConditions
        self.modelRoster = modelRoster
    }
}
