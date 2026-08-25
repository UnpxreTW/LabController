//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一個執行環境在某一刻的樣子；``ExecutionBackend/ps()`` 與 ``ExecutionBackend/status(of:)``
/// 回的都是這個。
public struct GuestSummary: Sendable, Equatable {

    /// 環境識別碼。
    public let identifier: GuestIdentifier

    /// 開這個環境用的基底。
    public let image: GuestImage

    /// 當下狀態。
    public let state: GuestState

    /// 建立時刻，由後端給。
    ///
    /// 用來看「這個環境開多久了」——孤兒回收與掛鐘預算都要這個數字，而由後端給才問得到
    /// 本側行程重啟之前就已經在跑的那些。
    public let startedAt: Date

    /// 逐欄建立。
    public init(identifier: GuestIdentifier, image: GuestImage, state: GuestState, startedAt: Date) {
        self.identifier = identifier
        self.image = image
        self.state = state
        self.startedAt = startedAt
    }
}
