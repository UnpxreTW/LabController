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
    case undecodableBody
}
