//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一件工單「算不算做完」的二元判準——執行端照這一條自評，判準本身機器可判、不留解釋空間。
///
/// **刻意做成封閉的一組值、不做成述詞語言**：能寫的判準只有這幾種，寫成可組合的比較式看似
/// 通用，實際上是把「什麼叫做完」這件事外包給每一張工單各自發明一次；發明錯了不會有人報錯，
/// 只會表現成某類 job 永遠判不完成。要多一種判準就在這裡多一個值，改動看得見、也審得到。
///
/// **這是自評、不是終審**：執行端依這一條回報結果，主控端仍以站台終態二次核對
/// （見 ``HostVerificationResult``）——兩層判準都是機器可判的，才有得對帳。
public enum JobCompletionCriteria: Sendable, Equatable {

    /// rebase：HEAD 為 `origin/<targetBranch>` 之後裔 ∧（SHA 有變 → push exit 0；SHA 未變 →
    /// 不 push 即完成）。
    ///
    /// 後半那個分岔是這條判準的重點：**乾淨且已經最新的分支不該 push**，卻會因為沒有一次
    /// 成功的 push 而被判成沒做完。把「沒事可做」算成完成，rebase 才是冪等的——跑完就不落後、
    /// 下一輪自然無事可做，於是收斂而不是自己觸發自己。
    case rebasedOntoTarget(targetBranch: String)

    /// build：建置命令 exit 0 ∧ 指定的產物都存在。
    ///
    /// 兩個條件缺一不可：只看 exit code 會把「編過了但什麼都沒產出」算成成功，而那正是下游
    /// 拿不到東西時最難查的一種綠。
    case buildProducedArtifacts(paths: [String])

    /// test：測試報告解析成功 ∧ 失敗數為零。
    ///
    /// 「報告解析成功」與「零失敗」是兩件事：報告壞掉、根本沒跑、或跑了但沒寫出報告，三種
    /// 情形下失敗數都會是零。少了前半，沒跑就等於全過。
    case testReportParsedWithZeroFailures

    /// lint：違規數不超過 baseline。
    ///
    /// 判準是「只減不增」而非「零違規」——存量違規不該擋住每一次改動，但也不許往上長。
    case lintWithinBaseline(maximumViolations: Int)

    /// llm-review：裁決已產出 ∧ 每一條 finding 的錨點都通過驗證。
    ///
    /// 錨點驗證是這一條的承重處：挑出問題會生出後續工作，指不出可驗證錨點的 finding 一律機械
    /// 丟棄、不交人判斷——否則講得頭頭是道但錯的那條，會讓系統自己長出工作。
    case reviewDeliveredWithVerifiedAnchors
}

extension JobCompletionCriteria: Codable {

    /// 判準在工單檔裡的欄位；扁平一層、`kind` 決定其餘欄位讀哪些。
    ///
    /// 不用編譯器合成的巢狀形，是因為工單檔的讀者不只有這一側——執行端的入口腳本也要讀得懂
    /// 它，多包一層只是替對面多做一次拆包。
    private enum CodingKeys: String, CodingKey {

        /// 判準種類。
        case kind

        /// `rebasedOntoTarget` 的目標分支。
        case targetBranch

        /// `buildProducedArtifacts` 的產物路徑。
        case artifactPaths

        /// `lintWithinBaseline` 的違規數上限。
        case maximumViolations
    }

    /// 判準種類的字面值；落在工單檔裡、與 ``JobShape`` 同採蛇底。
    private enum Kind: String, Codable {

        /// 對應 ``JobCompletionCriteria/rebasedOntoTarget(targetBranch:)``。
        case rebasedOntoTarget = "rebased_onto_target"

        /// 對應 ``JobCompletionCriteria/buildProducedArtifacts(paths:)``。
        case buildProducedArtifacts = "build_produced_artifacts"

        /// 對應 ``JobCompletionCriteria/testReportParsedWithZeroFailures``。
        case testReportParsedWithZeroFailures = "test_report_parsed_with_zero_failures"

        /// 對應 ``JobCompletionCriteria/lintWithinBaseline(maximumViolations:)``。
        case lintWithinBaseline = "lint_within_baseline"

        /// 對應 ``JobCompletionCriteria/reviewDeliveredWithVerifiedAnchors``。
        case reviewDeliveredWithVerifiedAnchors = "review_delivered_with_verified_anchors"
    }

    /// 依 case 寫出 `kind` 與該種類自己的欄位；用不到的欄位不寫，工單檔裡不留空欄。
    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .rebasedOntoTarget(targetBranch):
            try container.encode(Kind.rebasedOntoTarget, forKey: .kind)
            try container.encode(targetBranch, forKey: .targetBranch)
        case let .buildProducedArtifacts(paths):
            try container.encode(Kind.buildProducedArtifacts, forKey: .kind)
            try container.encode(paths, forKey: .artifactPaths)
        case .testReportParsedWithZeroFailures:
            try container.encode(Kind.testReportParsedWithZeroFailures, forKey: .kind)
        case let .lintWithinBaseline(maximumViolations):
            try container.encode(Kind.lintWithinBaseline, forKey: .kind)
            try container.encode(maximumViolations, forKey: .maximumViolations)
        case .reviewDeliveredWithVerifiedAnchors:
            try container.encode(Kind.reviewDeliveredWithVerifiedAnchors, forKey: .kind)
        }
    }

    /// 自工單檔讀回判準。
    ///
    /// 認不得的 `kind` 會照實丟解碼錯——**不落成一個「先當作完成」的預設值**：一件工單帶著
    /// 這一側讀不懂的完成判準，唯一安全的處置是根本不要開跑。缺欄位同理，由 `decode` 丟錯。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        let kind: Kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .rebasedOntoTarget:
            self = .rebasedOntoTarget(targetBranch: try container.decode(String.self, forKey: .targetBranch))
        case .buildProducedArtifacts:
            self = .buildProducedArtifacts(paths: try container.decode([String].self, forKey: .artifactPaths))
        case .testReportParsedWithZeroFailures:
            self = .testReportParsedWithZeroFailures
        case .lintWithinBaseline:
            self = .lintWithinBaseline(
                maximumViolations: try container.decode(Int.self, forKey: .maximumViolations)
            )
        case .reviewDeliveredWithVerifiedAnchors:
            self = .reviewDeliveredWithVerifiedAnchors
        }
    }
}
