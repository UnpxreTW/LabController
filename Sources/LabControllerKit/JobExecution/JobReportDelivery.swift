//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一次回寫走完之後，站台那一側到底收下了什麼。
///
/// 分成三種收法而不是回一個布林：呼叫端對這三種的處置完全不同——寫進去了就把這件 job 從
/// 手上放掉；站台說它已經不在跑了要停手、連重試都不必；只收下卻沒寫進去則是「這件事還沒
/// 結束」，得由呼叫端決定要不要再開一輪。壓成一個布林之後，第三種會被當成失敗，而失敗的
/// 處置通常是重跑整件 job。
public struct JobReportDelivery: Sendable, Equatable {

    /// 站台收下終態的方式。
    public enum Acceptance: String, Sendable, Equatable {

        /// 終態已寫入站台（200）。
        case written

        /// 站台說這件 job 已經不在跑了（取消、已結束，或這把 token 不再有效）。
        case aborted

        /// 站台一直只回「收下但還沒寫入」（202），送到次數上限仍未確認。
        case notAcknowledged
    }

    /// 這次終態怎麼被收下的。
    public let acceptance: Acceptance

    /// 那份 trace 是否整份送到站台。
    ///
    /// 為 false 時終態仍可能是 ``Acceptance/written``：CI 頁面上的結果是對的、只是 log 缺了
    /// 一截。兩者分開記，因為「結果不對」與「log 不全」在排查時是完全不同的兩件事。
    public let traceIsComplete: Bool

    /// 終態一共送了幾次；沒送出過（trace 階段就被叫停）時為 `0`。
    public let updateAttempts: Int

    /// 逐欄建立。
    ///
    /// - Parameters:
    ///   - acceptance: 終態的收法。
    ///   - traceIsComplete: trace 是否整份送達。
    ///   - updateAttempts: 終態送出次數。
    public init(acceptance: Acceptance, traceIsComplete: Bool, updateAttempts: Int) {
        self.acceptance = acceptance
        self.traceIsComplete = traceIsComplete
        self.updateAttempts = updateAttempts
    }
}
