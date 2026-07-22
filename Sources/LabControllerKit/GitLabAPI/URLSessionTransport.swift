//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 以 URLSession 實作的正式傳輸；逐次無狀態請求、TCP 連線復用交由 URLSession 管理。
public struct URLSessionTransport: HTTPTransport {

    /// 使用共用 session；本片無自訂逾時／代理需求。
    public init() {}

    /// 把 `HTTPRequest` 轉成 `URLRequest` 送出，回應收斂成狀態碼＋本體。
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest: URLRequest = .init(url: request.url)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body
        let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse: HTTPURLResponse = response as? HTTPURLResponse else {
            throw GitLabAPIError.invalidResponse
        }
        return .init(statusCode: httpResponse.statusCode, body: data)
    }
}
