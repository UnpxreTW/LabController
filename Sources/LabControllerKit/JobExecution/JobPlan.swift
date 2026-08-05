//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 消化過的 job payload：站台送來的原始欄位已解讀成執行端可以照著跑的形狀。
///
/// 只描述「要跑什麼」、不涉及「在哪跑」——沙箱、clone、程序啟動由後續切片承接。本型別
/// 刻意不持有任何執行器概念，也刻意不持有 job token：token 只在協議層用得到，讓它跟著
/// 執行計劃到處走，就是讓它多好幾個會被印出來的機會。
public struct JobPlan: Sendable, Equatable {

    /// job 識別碼。
    public let jobIdentifier: Int

    /// git 座標；站台未提供時為 nil。
    public let git: GitInfo?

    /// 依 payload 原順序排列的步驟；是否該跑逐一問 `JobStepWhen`。
    ///
    /// 每個步驟的 `timeoutSeconds` 已夾在 `timeoutSeconds`（job 預算）之內，`0` 仍代表
    /// 站台未宣告、執行端回落 job 預算。**這裡不會出現大於 job 預算的步驟逾時**——照著
    /// 步驟值跑就不會突破本機硬上限。
    public let steps: [JobStep]

    /// 要以環境變數形式注入的變數。
    public let environment: [JobVariable]

    /// 要以檔案形式落地的變數（`file: true`）。
    public let fileVariables: [JobVariable]

    /// trace 遮蔽規則，涵蓋所有標了 `masked` 的變數值。
    public let masker: TraceMasker

    /// 本次實際可跑的秒數，已夾在本機硬上限內。
    public let timeoutSeconds: Int

    /// 已宣告但本片略過、且不影響結果正確性的能力（目前只有 cache）。
    ///
    /// 非空時務必把訊息寫進 trace：略過一件 CI 檔要求的事而不留痕，下次有人查「為什麼
    /// 每次都重新下載依賴」時無從查起。
    public let warnings: [UnsupportedJobFeature]

    /// 以顯式欄位建立。
    public init(
        jobIdentifier: Int,
        git: GitInfo? = nil,
        steps: [JobStep] = [],
        environment: [JobVariable] = [],
        fileVariables: [JobVariable] = [],
        masker: TraceMasker = .init(maskedValues: []),
        timeoutSeconds: Int,
        warnings: [UnsupportedJobFeature] = []
    ) {
        self.jobIdentifier = jobIdentifier
        self.git = git
        self.steps = steps
        self.environment = environment
        self.fileVariables = fileVariables
        self.masker = masker
        self.timeoutSeconds = timeoutSeconds
        self.warnings = warnings
    }
}
