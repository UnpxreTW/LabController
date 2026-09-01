//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 領一次件的完整結果：這一輪發生了什麼，以及下一輪要帶的游標。
///
/// 游標與處置分開記，因為兩者的來源不同——游標由站台在「此刻沒有工作」那一支發，與這一輪
/// 有沒有跑東西無關；沿用時必須連沒領到的那些輪次一起帶著走，否則 long-poll 等於沒開。
public struct JobCycle: Sendable, Equatable {

    /// 這一輪領到什麼、又是怎麼收尾的。
    public enum Disposition: Sendable, Equatable {

        /// 此刻站台沒有可領的 job；屬正常路徑、非錯誤。
        case idle

        /// 收下、跑完、回寫。
        case handled(jobIdentifier: Int, outcome: JobOutcome, delivery: JobReportDelivery)

        /// 領到了但當面拒收（payload 裡有本 executor 消化不了的能力），拒收理由已寫回站台。
        case refused(jobIdentifier: Int, delivery: JobReportDelivery)
    }

    /// 這一輪的處置。
    public let disposition: Disposition

    /// 下一輪 `jobs/request` 要帶的游標；站台沒發新值時是沿用進來的那一個。
    public let cursor: String?

    /// 逐欄建立。
    ///
    /// - Parameters:
    ///   - disposition: 這一輪的處置。
    ///   - cursor: 下一輪要帶的游標。
    public init(disposition: Disposition, cursor: String?) {
        self.disposition = disposition
        self.cursor = cursor
    }

    /// 這一輪有沒有真的經手一件 job。
    ///
    /// 拒收也算經手：那件 job 已經指派給這台 runner、終態也寫回去了，`--once` 該在這裡收工，
    /// 不是繼續等到有一件跑得起來為止。
    public var didHandleJob: Bool {
        disposition != .idle
    }
}
