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

    /// 以顯式欄位建立；`headers`／`body` 預設為空。
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// 傳輸層回應；只保留狀態碼與本體，足供上層判定成敗與解碼。
public struct HTTPResponse: Sendable, Equatable {

    /// HTTP 狀態碼。
    public var statusCode: Int

    /// 回應本體。
    public var body: Data

    /// 以顯式欄位建立；`body` 預設為空。
    public init(statusCode: Int, body: Data = .init()) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// 最小 HTTP 傳輸介面；正式路徑用 URLSession 實作、測試注入假傳輸即可離線驗證上層邏輯。
public protocol HTTPTransport: Sendable {

    /// 送出請求並回傳回應；連線層失敗（DNS、逾時等）以拋錯表達。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
