//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一件工單准許碰的東西：可以寫哪些 ref、明文禁止哪些能力。
///
/// **邊界寫進工單、不是只寫進 prompt**——寫在提示裡的禁令要靠對面自律，寫在這裡的可以在動手
/// 之前比對。這一層是給執行端讀的規章，真正的底是憑證窄化：唯讀的 job 手上沒有推得動任何
/// 東西的憑證，「不要留言」對它不是規定、是做不到。
///
/// 兩件事分兩欄而不是一份清單：可以寫的是**白名單**（沒列到就不准），禁止的是**黑名單**
/// （列到就不准）。合成一欄就得替每一種能力都想一個 ref 形狀的寫法，而「留言」不是 ref。
public struct JobBoundary: Sendable, Equatable, Codable {

    /// 明文禁止的能力；即使憑證不小心給寬了，這一條仍要成立。
    ///
    /// 蛇底 raw value 與 ``JobShape`` 同理——落在工單檔裡、供非 Swift 的執行端讀。
    public enum ForbiddenCapability: String, Sendable, Equatable, Codable, CaseIterable {

        /// 呼叫站台 API：回寫一律由主控端做，執行端手上不該有 api scope 的憑證。
        case gitLabAPI = "gitlab_api"

        /// 動到本次工單以外的分支。
        case otherBranches = "other_branches"

        /// 在 issue 或 MR 上留言——不污染人在看的那一面。
        case comments
    }

    /// 准許寫入的 ref 樣式（如 `refs/heads/feature-x`）；空陣列＝這件工單不寫任何東西。
    public let allowedWrites: [String]

    /// 明文禁止的能力。
    public let forbidden: [ForbiddenCapability]

    /// 以顯式欄位建立。
    public init(allowedWrites: [String] = [], forbidden: [ForbiddenCapability] = []) {
        self.allowedWrites = allowedWrites
        self.forbidden = forbidden
    }

    /// 唯讀工單的邊界：什麼都不能寫、三種能力全禁。
    ///
    /// 給成具名的常數，是因為唯讀是多數 job 型的形狀（build／test／lint／review），每張工單
    /// 各自把三個值再列一次，遲早有一張會少列一項。
    public static let readOnly: Self = .init(
        allowedWrites: [],
        forbidden: ForbiddenCapability.allCases
    )

    /// 這件工單會不會寫東西。
    public var writesAnything: Bool { allowedWrites.isEmpty == false }
}
