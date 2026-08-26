//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 執行端交回來的結果檔：自評結果、做過什麼、佐證、停在哪一條收手條件。
///
/// **這是自述、不是終審**：主控端收回後仍以站台終態二次核對（見 ``HostVerificationResult``），
/// 兩層分開記，事後才查得出「執行端說完成、站台卻沒動」這種形狀。
///
/// **讀不回來就是系統層失敗**：結果檔缺欄、型別不符、`status` 是這一側不認得的值，一律照實
/// 丟錯（見 ``init(jsonData:)``），由呼叫端記成 ``JobOutcome/systemFailed`` 並依設定的上限決定
/// 要不要重派。缺欄補預設值等於把「執行端根本沒寫出結果」讀成一次正常收尾。
public struct JobResult: Sendable, Equatable, Codable {

    /// 佐證：可查證的東西，不放判斷。
    ///
    /// 分開放而不是攤平在結果裡，是因為這幾欄的角色不同——上面的欄位是執行端的**結論**，
    /// 這裡的是讓人回頭查那個結論的**材料**。
    public struct Evidence: Sendable, Equatable, Codable {

        /// 實際推上去的 commit SHA；沒推東西時為 `nil`。
        ///
        /// `nil` **不代表失敗**：乾淨且已經最新的分支本來就不該推，那是完成的一種
        /// （見 ``JobCompletionCriteria/rebasedOntoTarget(targetBranch:)``）。
        public let pushedSHA: String?

        /// 動過的檔案路徑。
        public let filesChanged: [String]

        /// 本次動用的 LLM 呼叫帳目；沒動用 LLM 的 job（如乾淨的 rebase）留空。
        public let llmCalls: [LLMCallRecord]

        /// 以顯式欄位建立。
        public init(pushedSHA: String? = nil, filesChanged: [String] = [], llmCalls: [LLMCallRecord] = []) {
            self.pushedSHA = pushedSHA
            self.filesChanged = filesChanged
            self.llmCalls = llmCalls
        }
    }

    /// 本次跑的是哪一版工單規格（抄自 ``JobSpec/specVersion``）。
    ///
    /// 沒有這一欄，事後就分不出成功率的變化是調了規格還是工作剛好簡單——調參要能歸因，
    /// 才不是憑印象調。
    public let specVersion: String

    /// 執行端依完成判準自評的結果。
    ///
    /// 三態 exit code 的對應寫在 ``JobOutcome`` 上：job 本身失敗不重試、系統層失敗可重試。
    public let status: JobOutcome

    /// 做過的事，人可讀的一句一條；供事後翻閱，不參與任何判斷。
    public let actions: [String]

    /// 佐證。
    public let evidence: Evidence

    /// 停在哪一條收手條件；跑完整趟、沒被任何條件攔下時為 `nil`。
    ///
    /// 這一欄是那本成果帳的重點：哪一條真的在攔東西、哪一條從來沒響過，只有逐次記下來才看得出。
    public let stoppedAt: JobAbortCondition?

    /// 是否需要人接手。
    public let needsHuman: Bool

    /// 失敗或需要人接手時的原因；正常完成時為 `nil`。
    public let reason: String?

    /// 以顯式欄位建立。
    public init(
        specVersion: String = JobSpec.currentVersion,
        status: JobOutcome,
        actions: [String] = [],
        evidence: Evidence = .init(),
        stoppedAt: JobAbortCondition? = nil,
        needsHuman: Bool = false,
        reason: String? = nil
    ) {
        self.specVersion = specVersion
        self.status = status
        self.actions = actions
        self.evidence = evidence
        self.stoppedAt = stoppedAt
        self.needsHuman = needsHuman
        self.reason = reason
    }
}

public extension JobResult {

    /// 自結果檔的位元組讀回。
    ///
    /// 不做任何寬鬆回退：認不得的 `status`、缺掉的必填欄一律丟錯。呼叫端接住之後記成系統層
    /// 失敗——「讀不懂執行端寫了什麼」與「執行端說它失敗了」是兩件事，但都不是完成。
    init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }

    /// 編成結果檔的位元組；鍵排序固定，同一份結果每次編出逐 byte 相同的內容。
    func jsonData() throws -> Data {
        let encoder: JSONEncoder = .init()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
