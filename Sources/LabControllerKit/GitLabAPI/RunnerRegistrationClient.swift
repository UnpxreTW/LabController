//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 註冊成功後由 GitLab 發回的 runner 身分。
public struct RegisteredRunner: Decodable, Sendable, Equatable {

    /// runner 於 GitLab 上的識別碼。
    public let id: Int

    /// runner 認證 token；僅於註冊回應揭露一次（one-shot reveal）、之後 API 不再提供。
    public let token: String

    /// 以顯式欄位建立（測試用；正式路徑一律由回應解碼而來）。
    public init(id: Int, token: String) {
        self.id = id
        self.token = token
    }
}

/// GitLab runner 註冊流程的最小 client：以 registration token 換認證 token、再以 `/verify` 驗證。
/// 只涵蓋註冊這一步；領 job、trace 回寫等協議面另隨後續開發加入。
public struct RunnerRegistrationClient: Sendable {

    /// 傳輸層；正式路徑用 `URLSessionTransport`、測試注入假傳輸。
    private let transport: any HTTPTransport

    /// 以指定傳輸建立；未指定時採 URLSession 正式路徑。
    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// `POST /api/v4/runners`：以 registration token 註冊、換取 runner 認證 token。
    /// 預期 201 Created；其餘狀態碼一律視為失敗拋錯。
    public func register(
        host: String,
        registrationToken: String,
        description: String? = nil
    ) async throws -> RegisteredRunner {
        let payload: RegistrationRequest = .init(token: registrationToken, description: description)
        let response: HTTPResponse = try await post(host: host, path: "runners", payload: payload)
        guard response.statusCode == 201 else {
            throw GitLabAPIError.unexpectedStatus(response.statusCode)
        }
        guard let runner: RegisteredRunner = try? JSONDecoder().decode(RegisteredRunner.self, from: response.body)
        else {
            throw GitLabAPIError.undecodableBody
        }
        return runner
    }

    /// `POST /api/v4/runners/verify`：驗證認證 token 於站台端仍有效。
    /// 預期 200／201；403 代表 token 無效，一律以狀態碼錯誤拋出。
    public func verify(host: String, token: String) async throws {
        let payload: VerificationRequest = .init(token: token)
        let response: HTTPResponse = try await post(host: host, path: "runners/verify", payload: payload)
        guard (200 ... 201).contains(response.statusCode) else {
            throw GitLabAPIError.unexpectedStatus(response.statusCode)
        }
    }

    /// 組出 `{host}/api/v4/{path}` 的 JSON POST 並送出；host 結尾多餘的斜線會先修剪。
    private func post(host: String, path: String, payload: some Encodable) async throws -> HTTPResponse {
        let base: String = host.hasSuffix("/") ? .init(host.dropLast()) : host
        guard let url: URL = .init(string: "\(base)/api/v4/\(path)"), url.scheme != nil else {
            throw GitLabAPIError.invalidURL(host)
        }
        let request: HTTPRequest = .init(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(payload)
        )
        return try await transport.send(request)
    }
}

/// `POST /api/v4/runners` 的請求本體；`description` 為 nil 時整鍵省略、交由站台端預設。
private struct RegistrationRequest: Encodable {

    /// registration token。
    let token: String

    /// 顯示於 runner 清單的描述文字。
    let description: String?
}

/// `POST /api/v4/runners/verify` 的請求本體。
private struct VerificationRequest: Encodable {

    /// runner 認證 token。
    let token: String
}
