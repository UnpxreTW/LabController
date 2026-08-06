//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 拒絕跟隨轉址的 task delegate。
///
/// 無狀態、無儲存屬性，故 `@unchecked Sendable` 成立（`NSObject` 子類無法自動推導）。
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// 一律不跟隨轉址：回傳 `nil` 讓 3xx 回應原樣交給呼叫端。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// 以 URLSession 實作的正式傳輸；逐次無狀態請求、TCP 連線復用交由 URLSession 管理。
///
/// **不跟隨轉址。** URLSession 預設會自動跟隨，而它只對 `Authorization` 做跨主機剝除；
/// 本模組的憑證走 `PRIVATE-TOKEN` 這類自訂標頭，**跨主機轉址時會原樣帶過去**——站台被改設定、
/// DNS 被換、或有人在中間插一個 302，讀取憑證就這樣送到別人家，而呼叫端只會看到一次成功的請求。
/// 拒絕跟隨之後，3xx 原樣回到上層、成為看得見的非預期狀態碼。
public struct URLSessionTransport: HTTPTransport {

    /// 共用的轉址拒絕器；無狀態，故單一實例即可。
    private static let redirectRefusing: RedirectRefusingDelegate = .init()

    /// 全型別共用的 session。
    ///
    /// **必須共用**：連線池與 TLS 交握都綁在 session 實例上，每次 `init` 各開一個
    /// 會讓每個 client 擁有自己的私有連線池、連線復用失效（同 session 連發四次
    /// 只握手一次，四個 session 則是四次）。而 `init(transport:)` 這種預設參數會
    /// 讓 client 隨手建立，數量不受控。
    ///
    /// 組態說明：`timeoutIntervalForResource` 是**單一請求的整體上限**、會硬蓋過
    /// per-request 的 `timeoutInterval`（實測 cfg 4 秒 + request 20 秒 → 4.75 秒就斷），
    /// 故設為遠高於 long-poll 逾時的值當保險絲，避免靜默夾住。
    /// `waitsForConnectivity` 維持關閉——它只作用於初次連線、會把 DNS 失敗當暫時性
    /// 而延後回報，拖慢自家重試節奏；重試由上層自己排。
    private static let shared: URLSession = {
        let configuration: URLSessionConfiguration = .default
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return .init(configuration: configuration)
    }()

    /// 實際送出請求的 session。
    private let session: URLSession

    /// 採用共用 session。
    public init() {
        self.session = Self.shared
    }

    /// 以指定 session 建立；供測試或特殊組態使用。
    public init(session: URLSession) {
        self.session = session
    }

    /// 把 `HTTPRequest` 轉成 `URLRequest` 送出，回應收斂成狀態碼＋本體＋標頭。
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest: URLRequest = .init(url: request.url)
        urlRequest.httpMethod = request.method
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body
        if let timeout: TimeInterval = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        let (data, response): (Data, URLResponse) = try await session.data(
            for: urlRequest,
            delegate: Self.redirectRefusing
        )
        guard let httpResponse: HTTPURLResponse = response as? HTTPURLResponse else {
            throw GitLabAPIError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (field, value) in httpResponse.allHeaderFields {
            guard let name: String = field as? String else { continue }
            headers[name] = .init(describing: value)
        }
        return .init(statusCode: httpResponse.statusCode, body: data, headers: headers)
    }
}
