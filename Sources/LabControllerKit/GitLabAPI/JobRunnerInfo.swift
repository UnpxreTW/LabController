//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 站台隨 job 一併送回的執行指示；對應協議 `runner_info`。
///
/// 與 `RunnerInfo` 方向相反、別混用：`RunnerInfo` 是領 job 時我方送出的自述，本型別
/// 是站台回給我們的。16.2 只有 `timeout` 與 `runner_session_url` 兩欄，本片消化前者。
public struct JobRunnerInfo: Decodable, Sendable, Equatable {

    /// 站台宣告的 job 逾時秒數；取自該 job 的 `metadata_timeout`。
    ///
    /// ⚠️ **不可直接當執行上限**：`.gitlab-ci.yml` 由各專案自己維護、可自設
    /// `timeout: 3h`，而執行池的格數是硬體上限——一個跑飛的 job 佔住格子，代價由後面
    /// 排隊的所有人一起付。一律先過 `JobTimeoutPolicy` 夾住再用。
    public let timeoutSeconds: Int

    /// 以顯式欄位建立（測試用；正式路徑一律由回應解碼而來）。
    public init(timeoutSeconds: Int = 0) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// 解碼；`timeout` 缺席視為 0（＝站台未宣告，由本機硬上限接手）。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 0
    }

    /// 對應站台端欄位名。
    private enum CodingKeys: String, CodingKey {
        case timeoutSeconds = "timeout"
    }
}
