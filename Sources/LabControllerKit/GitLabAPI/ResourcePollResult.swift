//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一輪輪詢的產物：讀到的資源、推進後的游標，以及本輪走到哪裡收尾。
///
/// 游標與資源一起回傳、而不是由輪詢器自己持有：輪詢器是無狀態的，**要不要接受這一輪**由呼叫端決定。
/// 事件寫進儲存層失敗時，呼叫端只要不保存新游標，下一輪就會重讀同一段——若游標的推進藏在輪詢器
/// 內部，那批事件就在「已讀過」與「未落地」之間永久消失。
public struct ResourcePollResult<Element: Sendable>: Sendable {

    /// 本輪讀到的資源，依 `updated_at` 由舊到新。
    ///
    /// **可能含上一輪已見過的內容**——游標刻意保守（見 `UpdatedAfterCursor`），去重是下游的職責。
    public let elements: [Element]

    /// 推進後的游標。呼叫端確認本輪產物已落地後才應保存。
    public let cursor: UpdatedAfterCursor

    /// 本輪走到哪裡收尾。
    public let completion: PollCompletion

    /// 以顯式欄位建立。
    public init(elements: [Element], cursor: UpdatedAfterCursor, completion: PollCompletion) {
        self.elements = elements
        self.cursor = cursor
        self.completion = completion
    }
}
