//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一件 job 執行完後的紀錄：派了什麼、guest 自評結果、host 二次核對結果、動用的 LLM 帳目。
///
/// 這是決策日誌兩種行之二（另一種是 ``DecisionRecord``）。它把三層判準的結果並排存下——
/// job 規格的內容指紋、guest 依 `done_when` 的自評、host 依站台終態的終審——因為系統對
/// 「算不算完成」的答案就是這三層的合成，事故取證時三層都要看得到。
public struct JobRecord: Sendable, Equatable, Codable {

    /// 日誌格式版本；與 ``DecisionLogEntry/schemaVersion`` 同源。
    public let schemaVersion: String

    /// 紀錄寫下的時刻（job 收尾時）。
    public let recordedAt: Date

    /// 觸發此 job 的事件去重鑰匙字串；與 ``DecisionRecord/eventKey`` 對得起來。
    public let eventKey: String

    /// 派工規格的內容指紋（JobSpec 的 sha）。
    ///
    /// 存指紋不存整份規格：規格可能含注入路徑等不宜落日誌的內容，指紋足以在事後比對
    /// 「跑的是不是這一版規格」，又不把規格本體攤在日誌裡。
    public let jobSpecSHA: String

    /// guest 依 `done_when` 自評的結果。
    public let guestResult: JobOutcome

    /// host 拿 guest 回報向站台終態二次核對的判定。
    public let hostVerification: HostVerificationResult

    /// 本 job 期間動用的 LLM 呼叫帳目；沒有動用 LLM 的 job（如 rebase 乾淨路徑）留空。
    public let llmCalls: [LLMCallRecord]

    /// 是否需要人接手（越界、能力不足、host 核對不符等）。
    public let needsHuman: Bool

    /// 需要人接手或失敗時的原因；正常完成時為 `nil`。
    public let reason: String?

    /// 以顯式欄位建立。
    public init(
        schemaVersion: String = DecisionLogEntry.schemaVersion,
        recordedAt: Date,
        eventKey: String,
        jobSpecSHA: String,
        guestResult: JobOutcome,
        hostVerification: HostVerificationResult,
        llmCalls: [LLMCallRecord] = [],
        needsHuman: Bool = false,
        reason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.recordedAt = recordedAt
        self.eventKey = eventKey
        self.jobSpecSHA = jobSpecSHA
        self.guestResult = guestResult
        self.hostVerification = hostVerification
        self.llmCalls = llmCalls
        self.needsHuman = needsHuman
        self.reason = reason
    }
}
