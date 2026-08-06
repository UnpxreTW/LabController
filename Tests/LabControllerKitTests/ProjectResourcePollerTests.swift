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
private final class ScriptedTransport: HTTPTransport, Sendable {

    /// 腳本用完了還被呼叫——代表待驗的翻頁次數與預期不符。
    enum ScriptError: Error {

        /// 沒有下一個回應可供回覆。
        case exhausted
    }

    /// 收到的請求，依序累積。
    let requests: Mutex<[HTTPRequest]> = .init([])

    /// 尚未送出的回應。
    private let pending: Mutex<[HTTPResponse]>

    /// 以回應腳本建立。
    init(_ responses: [HTTPResponse]) {
        self.pending = .init(responses)
    }

    /// 記錄請求後回覆腳本中的下一個回應。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
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
private struct SyntheticResource: Decodable, UpdatedAtCarrying {

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
private let reference: TimeInterval = 1_786_006_800

/// 組一頁回應；`serverDate` 傳 nil 即模擬站台沒送 `Date` 標頭。
private func pageResponse(
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
private func queryItems(of request: HTTPRequest) -> [String: String] {
    let components: URLComponents? = .init(url: request.url, resolvingAgainstBaseURL: false)
    return (components?.queryItems ?? []).reduce(into: [:]) { table, item in
        table[item.name] = item.value
    }
}

private final class ProjectResourcePollerTests {

    /// 請求形狀：GET、路徑、排序與翻頁參數、憑證放在 `PRIVATE-TOKEN` 標頭。
    @Test
    func `poll issues a get with the ordering the cursor depends on`() async throws {
        let transport: ScriptedTransport = .init([pageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init(watermark: .init(timeIntervalSince1970: reference))
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.method == "GET")
        #expect(request.url.path == "/api/v4/projects/42/merge_requests")
        #expect(request.headers["PRIVATE-TOKEN"] == "synthetic-read-token")
        let items: [String: String] = queryItems(of: request)
        #expect(items["order_by"] == "updated_at")
        #expect(items["sort"] == "asc")
        #expect(items["per_page"] == "100")
        #expect(items["page"] == "1")
        #expect(items["updated_after"] == "2026-08-06T09:00:00Z")
    }

    /// 首輪（游標未設）不帶 `updated_after`，代表讀全集。
    @Test
    func `first poll omits the updated after filter`() async throws {
        let transport: ScriptedTransport = .init([pageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com/",
            projectIdentifier: "42",
            collection: .issues,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(queryItems(of: request)["updated_after"] == nil)
        // host 結尾的斜線也一併修剪、不產生 //api 路徑。
        #expect(request.url.path == "/api/v4/projects/42/issues")
    }

    /// 以完整路徑指定專案時，斜線必須編碼成 `%2F`，否則會被當成多一層路徑而打到不存在的端點。
    @Test
    func `project path is percent encoded`() async throws {
        let transport: ScriptedTransport = .init([pageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "synthetic-group/synthetic-project",
            collection: .pipelines,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        let expected: String = "/api/v4/projects/synthetic-group%2Fsynthetic-project/pipelines"
        #expect(request.url.absoluteString.contains(expected))
    }

    /// 超過站台上限的每頁筆數在本地就夾住，且有效值可讀——站台對超限值不報錯、直接收小。
    @Test
    func `page size is clamped to the server maximum`() async throws {
        let transport: ScriptedTransport = .init([pageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport, pageSize: 500)
        #expect(poller.pageSize == ProjectResourcePoller.maximumPageSize)
        let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(queryItems(of: request)["per_page"] == "100")
    }

    /// 多頁走完：資源依序串起、翻頁靠 `X-Next-Page` 而非筆數，最後一頁的空字串即終止。
    @Test
    func `walk follows next page header until it is empty`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05.250Z"}]"#, page: 1, nextPage: 2),
            pageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:10Z"}]"#, page: 2, nextPage: 3),
            pageResponse(#"[{"id":3,"updated_at":"2026-08-06T09:00:20.750Z"}]"#, page: 3, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.elements.map(\.identifier) == [1, 2, 3])
        #expect(result.completion == .complete)
        // 三種時間戳形狀（帶／不帶小數秒）都要解得出來。
        #expect(result.elements.map(\.updatedAt) == [
            .init(timeIntervalSince1970: reference + 5.25),
            .init(timeIntervalSince1970: reference + 10),
            .init(timeIntervalSince1970: reference + 20.75),
        ])
        let pages: [String?] = transport.requests.withLock { $0.map { queryItems(of: $0)["page"] } }
        #expect(pages == ["1", "2", "3"])
    }

    /// 平順情況：走完最後一頁、且沒有資源晚於本輪起始時刻 → 游標推到本輪讀到的最大時刻。
    @Test
    func `undisturbed walk advances to the newest resource seen`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"}]"#, page: 1, nextPage: 2),
            pageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:20Z"}]"#, page: 2, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.completion == .complete)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 20))
    }

    /// 受擾情況：與上一例只差第二頁多一筆「本輪期間才被改動」的資源，游標就退回第一頁的最大時刻。
    ///
    /// 這一對是刻意配對的——上一例證明推進得動，本例證明偵測得出差異。少了任一半都不足以說明保守推進有效。
    @Test
    func `a write during the walk holds the cursor at the first page`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"}]"#, page: 1, nextPage: 2),
            pageResponse(
                #"[{"id":2,"updated_at":"2026-08-06T09:00:20Z"},{"id":3,"updated_at":"2026-08-06T09:00:45Z"}]"#,
                page: 2,
                nextPage: nil
            ),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.completion == .complete)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 5))
        // 資源本身照樣全數交出去，保守的只有游標。
        #expect(result.elements.map(\.identifier) == [1, 2, 3])
    }

    /// 撞到翻頁預算：游標同樣只推到第一頁的最大時刻，狀態標成截斷。
    @Test
    func `hitting the page budget truncates and advances only one page`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"}]"#, page: 1, nextPage: 2),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 1)
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.completion == .truncated)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 5))
        #expect(transport.requests.withLock { $0.count } == 1)
    }

    /// 撞到預算又推不動游標＝下一輪會讀到一模一樣的內容再撞一次；必須具名為 `stalled`。
    @Test
    func `budget exhausted without cursor progress reports a stall`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:00.900Z"}]"#, page: 1, nextPage: 2),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 1)
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: reference))
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: cursor
        )
        #expect(result.completion == .stalled)
        #expect(result.cursor == cursor)
        #expect(result.elements.count == 1)
    }

    /// 游標壓在站台時鐘之下：站台回報的時刻比讀到的資源早時，以站台時刻為準。
    @Test
    func `cursor is capped by the server clock`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:50Z"}]"#,
                page: 1,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:00:30 GMT"
            ),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 30))
    }

    /// 站台沒送 `Date` 標頭時退回本機時鐘、並往前扣容差；扣的方向只會造成重讀。
    @Test
    func `missing date header falls back to the local clock minus the allowance`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:09:00Z"}]"#, page: 1, nextPage: nil, serverDate: nil),
        ])
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            clockSkewAllowance: 120,
            localClock: { .init(timeIntervalSince1970: reference + 600) }
        )
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        // 本機時鐘 09:10:00 扣 120 秒＝09:08:00，早於資源的 09:09:00 → 以容差後的時刻封頂。
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 480))
    }

    /// 空集合不推進游標：沒讀到東西不代表那段時間沒有東西被改過。
    @Test
    func `empty result does not advance the cursor`() async throws {
        let transport: ScriptedTransport = .init([pageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: reference))
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: cursor
        )
        #expect(result.cursor == cursor)
        #expect(result.completion == .complete)
        #expect(result.elements.isEmpty)
    }

    /// 非 200（例如 token 無權讀該專案）應拋狀態碼錯誤、不當成空集合帶過。
    @Test
    func `non success status is surfaced`() async {
        let transport: ScriptedTransport = .init([.init(statusCode: 401)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.unexpectedStatus(401)) {
            let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                host: "https://gitlab.example.com",
                projectIdentifier: "42",
                collection: .mergeRequests,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
    }

    /// 本體解不開時拋解碼錯誤。
    @Test
    func `undecodable body is surfaced`() async {
        let transport: ScriptedTransport = .init([pageResponse("not json", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.undecodableBody) {
            let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                host: "https://gitlab.example.com",
                projectIdentifier: "42",
                collection: .mergeRequests,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
    }

    /// 時間戳解不出來時同樣整頁失敗、不靜默丟掉那一筆（丟掉就等於那個資源從未被偵測到）。
    @Test
    func `unparsable timestamp fails the page`() async {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"yesterday"}]"#, page: 1, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.undecodableBody) {
            let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                host: "https://gitlab.example.com",
                projectIdentifier: "42",
                collection: .mergeRequests,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
    }

    /// 分頁標頭壞掉時中止整輪，不靜默只讀第一頁。
    @Test
    func `malformed pagination aborts the walk`() async {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 200, body: .init("[]".utf8), headers: ["X-Next-Page": "2"]),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                host: "https://gitlab.example.com",
                projectIdentifier: "42",
                collection: .mergeRequests,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
    }

    /// 組不出帶 scheme 的網址時拋網址錯誤、不發出任何請求。
    @Test
    func `invalid host throws before any request`() async {
        let transport: ScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.invalidURL("")) {
            let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                host: "",
                projectIdentifier: "42",
                collection: .mergeRequests,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }
}
