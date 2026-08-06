//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Testing

/// 攔截 URLSession 請求的假協定：把「站台回 302 指向另一台主機」搬到本機、不需要真的連出去。
///
/// 用 `URLProtocol` 而不是假 `HTTPTransport`：要驗的是**傳輸層本身跟不跟隨轉址**，
/// 那是 URLSession 的行為，繞過它就等於什麼都沒驗到。
private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {

    /// 收到的請求標頭，依序累積；`nonisolated(unsafe)` 的理由是測試單執行緒逐一取用。
    nonisolated(unsafe) static var seenHeaders: [[String: String]] = []

    /// 攔截所有請求。
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// 不改寫請求。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 第一次回 302 指向另一台主機，之後回 200；兩次都記下收到的標頭。
    override func startLoading() {
        Self.seenHeaders.append(request.allHTTPHeaderFields ?? [:])
        let isFirst: Bool = Self.seenHeaders.count == 1
        let url: URL = request.url ?? URL(fileURLWithPath: "/")
        if isFirst {
            let target: String = "https://elsewhere.example/api/v4/projects/42/issues"
            let response: HTTPURLResponse? = .init(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target]
            )
            // 必須走 `wasRedirectedTo:`，URLSession 才會真的執行它的轉址處理（含詢問 delegate）；
            // 只把 302 當一般回應交出去，等於根本沒觸發要驗的那條路。
            if let response, let targetURL: URL = .init(string: target) {
                var followUp: URLRequest = .init(url: targetURL)
                followUp.allHTTPHeaderFields = request.allHTTPHeaderFields
                client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
        } else {
            let response: HTTPURLResponse? = .init(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
            if let response {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
        }
        client?.urlProtocol(self, didLoad: .init())
        client?.urlProtocolDidFinishLoading(self)
    }

    /// 無需取消處理。
    override func stopLoading() {}
}

private final class URLSessionTransportTests {

    /// 傳輸層**不得跟隨轉址**：憑證走 `PRIVATE-TOKEN` 這類自訂標頭，URLSession 只對 `Authorization`
    /// 做跨主機剝除，自訂標頭會原樣帶到轉址目的地。跟隨即等於把讀取憑證送到別人家，
    /// 而呼叫端只會看到一次成功的請求。
    @Test
    func `transport does not follow redirects`() async throws {
        RedirectingProtocol.seenHeaders = []
        let configuration: URLSessionConfiguration = .ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let transport: URLSessionTransport = .init(session: .init(configuration: configuration))
        let url: URL = try #require(.init(string: "https://gitlab.example.com/api/v4/projects/42/issues"))
        let response: HTTPResponse = try await transport.send(
            .init(method: "GET", url: url, headers: ["PRIVATE-TOKEN": "synthetic-read-token"])
        )
        // 302 原樣回到上層，成為看得見的非預期狀態碼。
        #expect(response.statusCode == 302)
        // 只發生一次請求：沒有第二次，也就沒有第二台主機收到憑證。
        #expect(RedirectingProtocol.seenHeaders.count == 1)
    }
}
