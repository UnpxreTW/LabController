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

    /// 分頁標頭缺席或彼此矛盾；附帶一句說明是哪裡對不上。
    ///
    /// 獨立成一個 case 而不併進 `invalidResponse`：分頁標頭壞掉時，回應本體通常是完全合法的一頁資料，
    /// 照收就是「只讀到第一頁」或「同一頁反覆讀」——兩者都不會有任何徵兆。此處拋錯是為了讓它出聲。
    case malformedPagination(String)
}
