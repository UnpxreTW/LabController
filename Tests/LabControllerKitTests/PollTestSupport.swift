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

/// 依序回覆預先排好的回應，並記錄收到的請求；讓翻頁邏輯可完全離線驗證。
final class PollScriptedTransport: HTTPTransport, Sendable {

    /// 腳本用完了還被呼叫——代表待驗的翻頁次數與預期不符。
    enum ScriptError: Error {

        /// 沒有下一個回應可供回覆。
        case exhausted
    }

    /// 收到的請求，依序累積。
    let requests: Mutex<[HTTPRequest]> = .init([])

    /// 尚未送出的回應。
    private let pending: Mutex<[HTTPResponse]>

    /// 每次 `send` 進來時先跑一次；供測試在「請求進行中」推進注入的時鐘。
    private let onSend: @Sendable () -> Void

    /// 以回應腳本建立。
    init(_ responses: [HTTPResponse], onSend: @escaping @Sendable () -> Void = {}) {
        self.pending = .init(responses)
        self.onSend = onSend
    }

    /// 記錄請求後回覆腳本中的下一個回應。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        onSend()
        requests.withLock { $0.append(request) }
        return try pending.withLock { queue in
            guard !queue.isEmpty else {
                throw ScriptError.exhausted
            }
            return queue.removeFirst()
        }
    }
}

/// 測試用的最小資源型別：只要求輪詢器用得到的兩個欄位。
struct PollSyntheticResource: Decodable, UpdatedAtCarrying {

    /// 站台端識別碼。
    let identifier: Int

    /// 最後更新時刻。
    let updatedAt: Date

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case updatedAt = "updated_at"
    }
}

/// 2026-08-06T09:00:00Z，作為以下各例的參考時刻。
let pollReference: TimeInterval = 1_786_006_800

/// 組一頁回應；`serverDate` 傳 nil 即模擬站台沒送 `Date` 標頭。
func pollPageResponse(
    _ json: String,
    page: Int,
    nextPage: Int?,
    serverDate: String? = "Thu, 06 Aug 2026 09:00:30 GMT"
) -> HTTPResponse {
    var headers: [String: String] = [
        "X-Page": .init(page),
        "X-Per-Page": "100",
        "X-Next-Page": nextPage.map(String.init) ?? "",
    ]
    if let serverDate {
        headers["Date"] = serverDate
    }
    return .init(statusCode: 200, body: .init(json.utf8), headers: headers)
}

/// 從請求網址取查詢參數對照表。
func pollQueryItems(of request: HTTPRequest) -> [String: String] {
    let components: URLComponents? = .init(url: request.url, resolvingAgainstBaseURL: false)
    return (components?.queryItems ?? []).reduce(into: [:]) { table, item in
        table[item.name] = item.value
    }
}
