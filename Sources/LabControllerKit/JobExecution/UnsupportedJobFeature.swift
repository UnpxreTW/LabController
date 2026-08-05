//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// payload 宣告了、但本 executor 尚未實作的能力。
///
/// 存在理由是「未及之處必須明確失敗、不得靜默」：站台把 job 交過來時，已假設 runner
/// 會照 CI 檔把每一件事做完。少做一件卻回綠，等於用一個假綠掩蓋沒發生的工作——最典型
/// 的是「綠了但產物沒存」，下游拿著空手的成功狀態往下走，錯誤要到很後面才浮出來。
public enum UnsupportedJobFeature: Sendable, Equatable {

    /// CI 檔指定了 container image。
    case image(name: String)

    /// CI 檔宣告了 services。
    case services(count: Int)

    /// CI 檔宣告了要上傳的產物。
    case artifacts(count: Int)

    /// 有上游 job 帶著要下載的產物。
    case dependencyArtifacts(jobNames: [String])

    /// CI 檔宣告了 cache。
    case cache(count: Int)

    /// 這項缺口該讓 job 紅、還是只警告。
    public enum Severity: Sendable, Equatable {

        /// job 直接紅，一個步驟都不跑。
        case fatal

        /// 只把訊息寫進 trace，照常執行。
        case warning
    }

    /// 本項的嚴重度。
    ///
    /// **只有 cache 是警告**：它是加速器，缺席只會慢、不會讓結果變錯。其餘每一項缺席
    /// 都會讓「跑完」與「跑對」脫鉤，因此一律紅。
    public var severity: Severity {
        switch self {
        case .cache:
            return .warning
        case .image, .services, .artifacts, .dependencyArtifacts:
            return .fatal
        }
    }

    /// 寫進 trace 的說明。
    ///
    /// 一律指名是哪個 keyword、缺的是什麼能力——寫成通用錯誤的話，讀 log 的人得回頭
    /// 翻 CI 檔猜是哪一行害的。
    public var traceMessage: String {
        switch self {
        case let .image(name):
            return "executor 不支援 image：CI 檔指定了「\(name)」，但本 runner 直接在既有環境執行、不拉 image。"
        case let .services(count):
            return "executor 不支援 services：CI 檔宣告了 \(count) 個 service。"
        case let .artifacts(count):
            return "executor 尚未實作產物上傳：CI 檔宣告了 \(count) 項 artifacts，照常跑完會變成「綠了但產物沒存」。"
        case let .dependencyArtifacts(jobNames):
            let names: String = jobNames.joined(separator: "、")
            return "executor 尚未實作產物下載：上游 job（\(names)）帶有本 job 依賴的產物。"
        case let .cache(count):
            return "executor 尚未實作 cache：CI 檔宣告的 \(count) 項快取本次略過，僅影響速度、不影響結果。"
        }
    }
}
