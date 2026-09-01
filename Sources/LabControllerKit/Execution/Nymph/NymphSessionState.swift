//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// nymph 回報的 guest 狀態，本側的線上形狀。
///
/// **與 ``GuestState`` 刻意分成兩個型別**：這一個要跟著對面走（多一種狀態就要多一個 case，
/// 否則整則回應解不開），而 ``GuestState`` 是本側協議的一部分、換一個後端也不該跟著動。
/// 兩者之間的對應寫在 ``NymphExecutionBackend`` 裡，是一處明確的翻譯，不是同一個列舉的兩個
/// 名字。
internal enum NymphSessionState: String, Decodable, Equatable, Sendable {

    /// 還沒開始開機。
    case idle

    /// 開機中，還沒到可以收命令的程度。
    case booting

    /// 可以收命令。
    case ready

    /// 已停止；還在表上，直到被清掉。
    case stopped
}
