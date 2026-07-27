//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 送往 GitLab 的最小 HTTP 請求描述；只帶本專案用得到的欄位。
public struct HTTPRequest: Sendable, Equatable {

    /// HTTP 方法（"GET"、"POST"⋯）。
    public var method: String

    /// 完整請求網址。
    public var url: URL

    /// 請求標頭。
    public var headers: [String: String]

    /// 請求本體；無本體時為 nil。
    public var body: Data?

    /// 此請求的逾時秒數；nil 表示沿用傳輸層預設。
    ///
    /// 存在理由：`jobs/request` 是 long-poll、站台端會把連線 hold 住約 50 秒才回
    /// 204，client 逾時必須**大於** hold，否則自己先斷線、白費被 hold 的連線又反覆
    /// 敲站台；trace／狀態回寫則相反、應短逾時快速失敗。兩者差異放在請求上表達。
    public var timeout: TimeInterval?

    /// 以顯式欄位建立；`headers`／`body`／`timeout` 預設為空。
    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// 傳輸層回應；狀態碼、本體與回應標頭。
///
/// 保留標頭的理由：runner 協議把兩件事只放在標頭裡——`jobs/request` 的
/// `X-GitLab-Last-Update` 游標、以及 trace 回寫時通知「此 job 已被取消」的狀態標頭。
/// 只收狀態碼與本體的話這兩者都讀不到。
public struct HTTPResponse: Sendable, Equatable {

    /// HTTP 狀態碼。
    public var statusCode: Int

    /// 回應本體。
    public var body: Data

    /// 回應標頭；鍵維持站台回傳的原始大小寫，查值請用 `headerValue(_:)`。
    public var headers: [String: String]

    /// 以顯式欄位建立；`body`／`headers` 預設為空。
    public init(statusCode: Int, body: Data = .init(), headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    /// 不分大小寫取標頭值；HTTP 標頭名稱本就大小寫不敏感、各層轉手後大小寫並不保證。
    public func headerValue(_ name: String) -> String? {
        let wanted: String = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

/// 最小 HTTP 傳輸介面；正式路徑用 URLSession 實作、測試注入假傳輸即可離線驗證上層邏輯。
public protocol HTTPTransport: Sendable {

    /// 送出請求並回傳回應；連線層失敗（DNS、逾時等）以拋錯表達。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
