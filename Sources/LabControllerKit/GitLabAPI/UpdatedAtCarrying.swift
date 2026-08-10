//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 帶有「最後更新時刻」的專案資源；輪詢游標靠這個欄位推進。
///
/// 只要求這一個欄位、不要求識別碼或任何內容欄位：游標的推進規則完全建立在時間軸上，
/// 資源長什麼樣是偵測器的事、與翻頁機制無關。各資源型別自行決定要解出哪些欄位。
///
/// 對應站台端的 `updated_at`。**該欄位在站台是排序鍵、不是版本號**——同一個交易裡批次
/// 更新的資源會共用同一個時刻，游標推進規則必須容得下這種平手，見 `UpdatedAfterCursor`。
public protocol UpdatedAtCarrying: Sendable {

    /// 站台記錄的最後更新時刻，對應 REST 回應的 `updated_at`。
    var updatedAt: Date { get }
}
