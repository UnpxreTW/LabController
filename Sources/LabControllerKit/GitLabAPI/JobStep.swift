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
    ///
    /// 對映不到時這裡是 `.onSuccess`，真正送來的字串留在 `unrecognisedRunCondition`——
    /// 讀這個欄位前先確認那個是 nil。
    public let runCondition: JobStepWhen

    /// 站台送來、但本片對映不到的 `when` 值；對映得到時為 nil。
    ///
    /// 存在理由是**回落值不可信**：`when` 決定的是「這步驟在哪種結果下該跑」，站台日後多
    /// 一個條件（例如只在取消時收拾現場）而我們回落成 `on_success`，那個步驟就會在正常成功
    /// 路徑上跑起來——不是少做一件事，是做了一件不該做的事。故由 `JobResponse` 收進
    /// `unreadableFields`、`JobAdmission` 據以拒收。
    public let unrecognisedRunCondition: String?

    /// 以顯式欄位建立（測試用；正式路徑一律由回應解碼而來）。
    public init(
        name: String,
        script: [String],
        allowFailure: Bool = false,
        timeoutSeconds: Int = 0,
        runCondition: JobStepWhen = .onSuccess,
        unrecognisedRunCondition: String? = nil
    ) {
        self.name = name
        self.script = script
        self.allowFailure = allowFailure
        self.timeoutSeconds = timeoutSeconds
        self.runCondition = runCondition
        self.unrecognisedRunCondition = unrecognisedRunCondition
    }

    /// 解碼；`script` 缺席視為空、`allow_failure` 缺席視為 false、`timeout` 缺席視為 0。
    ///
    /// `when` 走「解成字串再對映」而非直接解成 enum：站台將來多一個條件值時，直接解 enum
    /// 會讓整包 payload 解不開、job 被當成解碼失敗丟掉。**但對映不到不等於可以裝作沒事**
    /// ——原字串留在 `unrecognisedRunCondition`，由收件判定擋下。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.script = try container.decodeIfPresent([String].self, forKey: .script) ?? []
        self.allowFailure = try container.decodeIfPresent(Bool.self, forKey: .allowFailure) ?? false
        self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 0
        let condition: String? = try container.decodeIfPresent(String.self, forKey: .runCondition)
        let mapped: JobStepWhen? = condition.flatMap(JobStepWhen.init(rawValue:))
        self.runCondition = mapped ?? .onSuccess
        self.unrecognisedRunCondition = mapped == nil ? condition : nil
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
