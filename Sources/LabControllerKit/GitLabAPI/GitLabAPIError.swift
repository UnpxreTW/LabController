//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// GitLab API 呼叫的錯誤模型；涵蓋網址組裝、回應形狀與狀態碼三類失敗。
public enum GitLabAPIError: Error, Equatable, Sendable {

    /// host 字串組不出帶 scheme 的合法網址。
    case invalidURL(String)

    /// 回應不是 HTTP 回應（傳輸層形狀異常）。
    case invalidResponse

    /// 狀態碼不在該端點的預期範圍內。
    case unexpectedStatus(Int)

    /// 回應本體解不出預期的 JSON 形狀。
    ///
    /// `codingPath` 是解不開的位置（如 `id`），**刻意只帶鍵名、不帶值**：這條錯誤會被寫進
    /// log，而 body 裡有 job token 與變數值。空字串代表拿不到位置資訊。
    ///
    /// 帶著位置是因為「body 解不開」單獨一句話查不動——`JobResponse` 現在只有 `id`／`token`
    /// 缺席會走到這裡，而這兩者缺哪一個、下一步完全不同。
    case undecodableBody(codingPath: String = "")
}
