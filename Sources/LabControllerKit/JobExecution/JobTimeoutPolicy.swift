//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// job 執行時間的上限政策：站台宣告值與本機硬上限取小者。
///
/// **為什麼不能只信站台宣告**：`.gitlab-ci.yml` 由各專案自己維護、可自設 `timeout: 3h`，
/// 而執行池的格數是硬體上限。上限握在宣告端等於沒有上限——一個跑飛的 job 佔住格子，
/// 代價由後面排隊的所有人一起付。所以夾在執行端、不商量。
public struct JobTimeoutPolicy: Sendable, Equatable {

    /// 未另行設定時採用的硬上限秒數。
    ///
    /// 取 3600（1 小時）是為了對齊站台自身的預設 job 逾時，讓「沒設 timeout 的 job」
    /// 兩邊看到同一個數字、不會有人以為被偷偷砍了。**這是運維參數、預期依實際負載調整**，
    /// 不是協議常數。
    public static let defaultHardLimitSeconds: Int = 3600

    /// 本機硬上限秒數；任何 job 都不得超過。
    public let hardLimitSeconds: Int

    /// 以硬上限建立；未指定時採預設值。非正值會被夾成 1 秒（＝設定寫錯時寧可讓 job
    /// 立刻逾時而顯眼失敗，也不要靜默變成無上限）。
    public init(hardLimitSeconds: Int = Self.defaultHardLimitSeconds) {
        self.hardLimitSeconds = max(hardLimitSeconds, 1)
    }

    /// 算出這個 job 實際可跑多久。
    ///
    /// 站台沒宣告（nil）或宣告非正值時回落硬上限——「沒說」不等於「不限」。
    public func effectiveSeconds(declaredSeconds: Int?) -> Int {
        guard let declaredSeconds, declaredSeconds > 0 else { return hardLimitSeconds }
        return min(declaredSeconds, hardLimitSeconds)
    }
}
