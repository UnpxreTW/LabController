//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// job 的一個執行步驟；本片解讀形狀與執行條件，實際跑起來由後續切片承接。
public struct JobStep: Decodable, Sendable, Equatable {

    /// 步驟名稱，例如 `script`、`after_script`。
    public let name: String

    /// 該步驟要跑的指令列。
    public let script: [String]

    /// 失敗是否可容忍。
    public let allowFailure: Bool

    /// 站台為此步驟宣告的逾時秒數；0 代表未宣告。
    ///
    /// 16.2 給每個步驟的都是**同一個** `metadata_timeout`（＝job 級逾時），不是各步驟
    /// 的獨立預算；照著它逐步驟各給一份，整個 job 就能跑到宣告值的好幾倍。
    ///
    /// ⚠️ 本型別直接解自 payload、**這個值是站台原樣宣告、未經任何夾制**。要拿來當執行
    /// 上限用的是 `JobPlan.steps` 裡那一份（已由 `JobAdmission` 夾進 job 預算）。
    public let timeoutSeconds: Int

    /// 此步驟在什麼結果下才跑；對應協議欄位 `when`。
    public let runCondition: JobStepWhen

    /// 以顯式欄位建立（測試用；正式路徑一律由回應解碼而來）。
    public init(
        name: String,
        script: [String],
        allowFailure: Bool = false,
        timeoutSeconds: Int = 0,
        runCondition: JobStepWhen = .onSuccess
    ) {
        self.name = name
        self.script = script
        self.allowFailure = allowFailure
        self.timeoutSeconds = timeoutSeconds
        self.runCondition = runCondition
    }

    /// 解碼；`script` 缺席視為空、`allow_failure` 缺席視為 false、`timeout` 缺席視為 0。
    ///
    /// `when` 走「解成字串再對映」而非直接解成 enum：站台將來多一個條件值時，直接解
    /// enum 會讓整包 payload 解不開、job 被當成解碼失敗丟掉；對映不到時回落
    /// `on_success` 只會少跑一個步驟，止損範圍小得多。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.script = try container.decodeIfPresent([String].self, forKey: .script) ?? []
        self.allowFailure = try container.decodeIfPresent(Bool.self, forKey: .allowFailure) ?? false
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 0
        let condition: String? = try container.decodeIfPresent(String.self, forKey: .runCondition)
        self.runCondition = condition.flatMap(JobStepWhen.init(rawValue:)) ?? .onSuccess
    }

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case name
        case script
        case allowFailure = "allow_failure"
        case timeoutSeconds = "timeout"
        case runCondition = "when"
    }
}
