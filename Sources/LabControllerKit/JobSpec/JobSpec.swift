//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一件工單的本體：要做到什麼、怎麼算做完、准許碰什麼、依哪些規則、迴圈的話跑到哪算久。
///
/// **這一份是設計上就要被寫出去的**——它會落成執行環境裡的工單檔、指紋會進決策日誌
/// （``JobRecord/jobSpecSHA``）。與 ``JobPlan`` 正好相反：那一份持有變數原值與遮蔽規則、
/// **明文帶著秘密所以不得序列化**；這一份沒有任何裝得下秘密的欄位，憑證循另一條路窄化投遞、
/// 不經工單。兩者名字相近、方向相反，改任一邊之前先看清楚在改哪一份。
///
/// **形狀與治理欄位綁死**：迴圈形一定帶治理欄位、跑一趟的一定不帶，唯讀的迴圈一定不寫任何
/// 東西。這三條在建立與讀回兩端都把關（見 ``CodingFailure``），因為工單可能來自這一側以外的
/// 產生者，而一張「唯讀但宣告了可寫 ref」的工單，光看欄位是看不出哪一半才是本意的。
public struct JobSpec: Sendable, Equatable {

    /// 建立或讀回工單時，形狀與欄位對不起來的具名原因；不吞錯、不以預設值代過。
    public enum CodingFailure: Error, Equatable {

        /// 迴圈形工單缺治理欄位——沒有盡頭的迴圈不准開跑。
        case governanceMissingForSession(JobShape)

        /// 跑一趟的工單卻帶了治理欄位；那些門檻不會有人讀，留著只會讓人以為它們在生效。
        case governanceOnBatchJob

        /// 唯讀的迴圈宣告了可寫的 ref。
        case readOnlySessionDeclaresWrites

        /// 編碼結果不是合法 UTF-8（理論上不會發生，但不以強制解包假設它不發生）。
        case notUTF8
    }

    /// 工單規格的版本；結果檔會抄一份回來（見 ``JobResult/specVersion``）。
    ///
    /// 沒有這個欄位，一個月後就分不出「成功率變好」是因為調了規格還是那批工作剛好簡單——
    /// 而「持續調整」若不能事後歸因，調的就只是心情。
    public static let currentVersion: String = "v1"

    /// 本工單依循的規格版本。
    public let specVersion: String

    /// 執行形狀。
    public let shape: JobShape

    /// 目標，自然語言一句；判準不寫在這裡（見 ``completion``）。
    public let goal: String

    /// 完成判準，機器可判的二元條件。
    public let completion: JobCompletionCriteria

    /// 准許碰的東西。
    public let boundary: JobBoundary

    /// 隨工單帶進去的規則原文節錄。
    public let rules: [JobRuleFragment]

    /// 迴圈形的治理欄位；跑一趟的工單為 `nil`。
    public let governance: SessionGovernance?

    /// 以顯式欄位建立。
    ///
    /// 私有：合法的工單只能經下方三個具名入口產生，那三個入口各自把形狀與欄位配好，不變式
    /// 在建立處即成立、不需要在這裡再擋一次。自外部讀回的工單另走 ``validate(shape:boundary:governance:)``。
    private init(
        specVersion: String,
        shape: JobShape,
        goal: String,
        completion: JobCompletionCriteria,
        boundary: JobBoundary,
        rules: [JobRuleFragment],
        governance: SessionGovernance?
    ) {
        self.specVersion = specVersion
        self.shape = shape
        self.goal = goal
        self.completion = completion
        self.boundary = boundary
        self.rules = rules
        self.governance = governance
    }

    /// 驗三條形狀不變式；讀回外來工單時用。
    ///
    /// 工單可能來自這一側以外的產生者，而一張「唯讀但宣告了可寫 ref」的工單，光看欄位看不出
    /// 哪一半才是本意——照實丟錯、不猜。
    private static func validate(shape: JobShape, boundary: JobBoundary, governance: SessionGovernance?) throws {
        if shape.isSession, governance == nil { throw CodingFailure.governanceMissingForSession(shape) }
        if shape.isSession == false, governance != nil { throw CodingFailure.governanceOnBatchJob }
        if shape == .readOnlySession, boundary.writesAnything { throw CodingFailure.readOnlySessionDeclaresWrites }
    }
}

public extension JobSpec {

    /// 跑一趟的工單：rebase／build／test／lint。
    ///
    /// 做成具名的入口而不是開放的初始化器，是為了讓「跑一趟卻帶了治理欄位」這種工單在這一側
    /// 根本寫不出來——擋在建立處，比擋在讀回處早一步。
    static func batch(
        goal: String,
        completion: JobCompletionCriteria,
        boundary: JobBoundary,
        rules: [JobRuleFragment] = []
    ) -> Self {
        .init(
            specVersion: currentVersion,
            shape: .batch,
            goal: goal,
            completion: completion,
            boundary: boundary,
            rules: rules,
            governance: nil
        )
    }

    /// 不寫 repo 的迴圈工單：llm-review。
    ///
    /// 不收 ``JobBoundary`` 參數——唯讀就是 ``JobBoundary/readOnly``，讓呼叫端傳一份等於留了
    /// 一個可以傳錯的位置。
    static func readOnlySession(
        goal: String,
        completion: JobCompletionCriteria,
        governance: SessionGovernance,
        rules: [JobRuleFragment] = []
    ) -> Self {
        .init(
            specVersion: currentVersion,
            shape: .readOnlySession,
            goal: goal,
            completion: completion,
            boundary: .readOnly,
            rules: rules,
            governance: governance
        )
    }

    /// 會寫 repo 的迴圈工單：issue 實作、CI 修復。
    static func developmentSession(
        goal: String,
        completion: JobCompletionCriteria,
        boundary: JobBoundary,
        governance: SessionGovernance,
        rules: [JobRuleFragment] = []
    ) -> Self {
        .init(
            specVersion: currentVersion,
            shape: .developmentSession,
            goal: goal,
            completion: completion,
            boundary: boundary,
            rules: rules,
            governance: governance
        )
    }
}

extension JobSpec: Codable {

    /// 工單檔的欄位。
    private enum CodingKeys: String, CodingKey {

        /// 規格版本。
        case specVersion

        /// 執行形狀。
        case shape

        /// 目標。
        case goal

        /// 完成判準。
        case completion

        /// 邊界。
        case boundary

        /// 規則節錄。
        case rules

        /// 治理欄位。
        case governance
    }

    /// 寫出工單；跑一趟的工單不寫 `governance` 鍵，檔裡不留空欄。
    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(specVersion, forKey: .specVersion)
        try container.encode(shape, forKey: .shape)
        try container.encode(goal, forKey: .goal)
        try container.encode(completion, forKey: .completion)
        try container.encode(boundary, forKey: .boundary)
        try container.encode(rules, forKey: .rules)
        try container.encodeIfPresent(governance, forKey: .governance)
    }

    /// 讀回工單，並在讀回處再驗一次三條形狀不變式。
    ///
    /// ⚠ 這裡刻意**不驗 `specVersion`**：版本是事後歸因用的佐證，不是解碼閘；驗它會讓舊版
    /// 執行端讀不過新版工單，而版本欄的用途本來就不是擋。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        let shape: JobShape = try container.decode(JobShape.self, forKey: .shape)
        let boundary: JobBoundary = try container.decode(JobBoundary.self, forKey: .boundary)
        let governance: SessionGovernance? = try container.decodeIfPresent(SessionGovernance.self, forKey: .governance)
        try Self.validate(shape: shape, boundary: boundary, governance: governance)
        self.init(
            specVersion: try container.decode(String.self, forKey: .specVersion),
            shape: shape,
            goal: try container.decode(String.self, forKey: .goal),
            completion: try container.decode(JobCompletionCriteria.self, forKey: .completion),
            boundary: boundary,
            rules: try container.decode([JobRuleFragment].self, forKey: .rules),
            governance: governance
        )
    }
}

public extension JobSpec {

    /// 把工單編成工單檔的位元組。
    ///
    /// 鍵排序固定，因此同一份工單每次編出**逐 byte 相同**的內容——指紋才對得起來：
    /// ``JobRecord/jobSpecSHA`` 存的是這份位元組的雜湊，而不是工單本體（工單可能帶著不宜落
    /// 日誌的內容，指紋足以事後比對「跑的是不是這一版」）。雜湊由呼叫端算，本型別不挑演算法。
    func jsonData() throws -> Data {
        let encoder: JSONEncoder = .init()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 自工單檔的位元組讀回工單。
    init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }
}
