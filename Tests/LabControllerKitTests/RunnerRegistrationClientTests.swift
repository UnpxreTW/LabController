//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Synchronization
import Testing

/// 記錄請求並回覆固定回應的假傳輸；讓 client 邏輯可完全離線驗證（合成資料、零真實站台）。
private final class RecordingTransport: HTTPTransport, Sendable {

    /// 收到的請求，依序累積。
    let requests: Mutex<[HTTPRequest]> = .init([])

    /// 每次 `send` 都回覆的固定回應。
    private let response: HTTPResponse

    /// 以固定回應建立。
    init(response: HTTPResponse) {
        self.response = response
    }

    /// 記錄請求後回覆固定回應。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.withLock { $0.append(request) }
        return response
    }
}

private final class RunnerRegistrationClientTests {

    /// 201＋合法 JSON：回傳解碼後的 runner 身分，且請求打在 `POST {host}/api/v4/runners`。
    @Test
    func `register succeeds on 201 and decodes runner`() async throws {
        let body: Data = .init(#"{"id":42,"token":"synthetic-auth"}"#.utf8)
        let transport: RecordingTransport = .init(response: .init(statusCode: 201, body: body))
        let client: RunnerRegistrationClient = .init(transport: transport)
        let runner: RegisteredRunner = try await client.register(
            host: "https://gitlab.example.com",
            registrationToken: "synthetic-registration",
            description: "synthetic runner"
        )
        #expect(runner == RegisteredRunner(id: 42, token: "synthetic-auth"))
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://gitlab.example.com/api/v4/runners")
        #expect(request.headers["Content-Type"] == "application/json")
        let bodyData: Data = try #require(request.body)
        let payload: [String: String] = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        )
        #expect(payload["token"] == "synthetic-registration")
        #expect(payload["description"] == "synthetic runner")
    }

    /// 未給描述時，請求本體整鍵省略 `description`。
    @Test
    func `register omits description key when nil`() async throws {
        let body: Data = .init(#"{"id":7,"token":"synthetic-auth"}"#.utf8)
        let transport: RecordingTransport = .init(response: .init(statusCode: 201, body: body))
        let client: RunnerRegistrationClient = .init(transport: transport)
        _ = try await client.register(host: "https://gitlab.example.com", registrationToken: "synthetic-registration")
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        let bodyData: Data = try #require(request.body)
        let payload: [String: String] = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        )
        #expect(payload["description"] == nil)
    }

    /// host 結尾多餘的斜線會被修剪，不會產生 `//api` 路徑。
    @Test
    func `register trims trailing slash in host`() async throws {
        let body: Data = .init(#"{"id":7,"token":"synthetic-auth"}"#.utf8)
        let transport: RecordingTransport = .init(response: .init(statusCode: 201, body: body))
        let client: RunnerRegistrationClient = .init(transport: transport)
        _ = try await client.register(host: "https://gitlab.example.com/", registrationToken: "synthetic-registration")
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.url.absoluteString == "https://gitlab.example.com/api/v4/runners")
    }

    /// 非 201 狀態碼（例如 403 registration token 無效）應拋狀態碼錯誤。
    @Test
    func `register throws on unexpected status`() async {
        let transport: RecordingTransport = .init(response: .init(statusCode: 403))
        let client: RunnerRegistrationClient = .init(transport: transport)
        await #expect(throws: GitLabAPIError.unexpectedStatus(403)) {
            try await client.register(host: "https://gitlab.example.com", registrationToken: "synthetic-registration")
        }
    }

    /// 201 但本體不是預期 JSON 形狀：應拋解碼錯誤。
    @Test
    func `register throws on undecodable body`() async {
        let transport: RecordingTransport = .init(response: .init(statusCode: 201, body: .init("not json".utf8)))
        let client: RunnerRegistrationClient = .init(transport: transport)
        await #expect(throws: GitLabAPIError.undecodableBody) {
            try await client.register(host: "https://gitlab.example.com", registrationToken: "synthetic-registration")
        }
    }

    /// 組不出帶 scheme 的網址（空 host）應拋網址錯誤、不發出任何請求。
    @Test
    func `register throws on invalid host`() async {
        let transport: RecordingTransport = .init(response: .init(statusCode: 201))
        let client: RunnerRegistrationClient = .init(transport: transport)
        await #expect(throws: GitLabAPIError.invalidURL("")) {
            try await client.register(host: "", registrationToken: "synthetic-registration")
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    /// 200：驗證通過，且請求打在 `POST {host}/api/v4/runners/verify`、本體帶 token。
    @Test
    func `verify succeeds on 200`() async throws {
        let transport: RecordingTransport = .init(response: .init(statusCode: 200))
        let client: RunnerRegistrationClient = .init(transport: transport)
        try await client.verify(host: "https://gitlab.example.com", token: "synthetic-auth")
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://gitlab.example.com/api/v4/runners/verify")
        let bodyData: Data = try #require(request.body)
        let payload: [String: String] = try #require(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        )
        #expect(payload["token"] == "synthetic-auth")
    }

    /// 403 代表 token 無效：應拋狀態碼錯誤。
    @Test
    func `verify throws on unexpected status`() async {
        let transport: RecordingTransport = .init(response: .init(statusCode: 403))
        let client: RunnerRegistrationClient = .init(transport: transport)
        await #expect(throws: GitLabAPIError.unexpectedStatus(403)) {
            try await client.verify(host: "https://gitlab.example.com", token: "synthetic-auth")
        }
    }
}
