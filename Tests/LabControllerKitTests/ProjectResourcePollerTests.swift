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

}

private final class ProjectResourcePollerCursorTests {

    /// 單頁走完：第一頁就是全部，游標推到讀到的最大時刻——穩定運轉時的常態，推進毫無損失。
    @Test
    func `single page walk advances to the newest resource seen`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"},{"id":2,"updated_at":"2026-08-06T09:00:20Z"}]"#,
                page: 1,
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
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 20))
    }

    /// 多頁走完：即使走到最後一頁、即使全部資源都早於本輪起始時刻，游標仍只推到**第一頁**的最大時刻。
    ///
    /// 第二頁以後不能採信：翻頁途中若有資源被刪除或改動，後面的資源會整體前移而跨過已讀邊界，
    /// 且刪除不留任何新時間戳、無從偵測。上一例（單頁）證明推進得動，本例證明多頁時確實只採信第一頁。
    @Test
    func `multi page walk advances only to the first page maximum`() async throws {
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
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 5))
        // 資源本身照樣全數交出去，保守的只有游標。
        #expect(result.elements.map(\.identifier) == [1, 2])
    }

    /// 撞到翻頁預算時同樣只推第一頁。
    ///
    /// 預算刻意設 2 並讓第二頁的最大時刻晚於第一頁：若規則被改成「推到最後讀到的那頁」，本例會抓到，
    /// 單頁的截斷案例則抓不到（那時兩者相等）。
    @Test
    func `hitting the page budget advances only to the first page maximum`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"}]"#, page: 1, nextPage: 2),
            pageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:20Z"}]"#, page: 2, nextPage: 3),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 2)
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.completion == .truncated)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 5))
        #expect(result.elements.map(\.identifier) == [1, 2])
        // 預算用完就停，不再多要第三頁。
        #expect(transport.requests.withLock { $0.count } == 2)
    }

    /// 本輪起始時刻只取自**第一個**回應：逐頁刷新會讓上限跟著往後漂，等於沒有上限。
    ///
    /// 第一頁的站台時刻 09:00:10 早於該頁最大值 09:00:30，游標應被壓到 09:00:10；
    /// 若改成每頁刷新，最後採用的會是第二頁的 09:01:00，游標就變成 09:00:30。
    @Test
    func `walk start is taken from the first response only`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:30Z"}]"#,
                page: 1,
                nextPage: 2,
                serverDate: "Thu, 06 Aug 2026 09:00:10 GMT"
            ),
            pageResponse(
                #"[{"id":2,"updated_at":"2026-08-06T09:00:40Z"}]"#,
                page: 2,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:01:00 GMT"
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
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 10))
    }

    /// 有東西可推進、卻被上限壓住而動不了，同樣是會自我重複的狀態，即使沒撞到翻頁預算也要報 `stalled`。
    ///
    /// 場景：站台沒送 `Date` 標頭、本機時鐘又落後站台一小時 → 起始時刻早於所有資源 → 游標永遠不動，
    /// 而每一輪都會回報 `complete`，看起來像「什麼都沒發生」。
    @Test
    func `cursor blocked by a bogus clock reports a stall even when not truncated`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:20Z"}]"#, page: 1, nextPage: nil, serverDate: nil),
        ])
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            localClock: { .init(timeIntervalSince1970: reference - 3600) }
        )
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
    }

    /// 同一秒的資源塞滿第一頁時，游標推不動——**不自作主張跨過去**，改回報 `stalled`。
    ///
    /// 跨過去需要「那一秒已讀完」的證據，而唯一的來源是第二頁以後；站台對 `updated_at` 沒有第二排序鍵，
    /// 時間戳相同的資源在不同次請求之間順序未定，所以那個證據推論不成立。照它跨過去，
    /// 沒露過面的同時刻資源就此沉到水位之下、永遠讀不到。卡住則一筆都沒丟。
    @Test
    func `an oversized tie group on the first page stalls instead of being crossed`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:00.100Z"},{"id":2,"updated_at":"2026-08-06T09:00:00.900Z"}]"#,
                page: 1,
                nextPage: 2
            ),
            pageResponse(
                #"[{"id":3,"updated_at":"2026-08-06T09:00:20Z"},{"id":4,"updated_at":"2026-08-06T09:00:25Z"}]"#,
                page: 2,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:01:00 GMT"
            ),
        ])
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
        #expect(result.completion == .stalled)
        // 卡住不等於不交件：讀到的資源照樣全數交出去。
        #expect(result.elements.map(\.identifier) == [1, 2, 3, 4])
    }

    /// 整輪預算都還在同一秒內：跨不出去，游標維持不動並報 `stalled`——絕不硬跳過還沒讀到的同秒資源。
    @Test
    func `a tie group larger than the whole budget stalls instead of skipping`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:00.100Z"}]"#, page: 1, nextPage: 2),
            pageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:00.900Z"}]"#, page: 2, nextPage: 3),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 2)
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
    }

    /// 第一頁是空的卻還有下一頁：那是異常，**不是**同秒群。此時沒有任何第一頁證據，游標不得憑第二頁前進。
    @Test
    func `an empty first page never counts as a tie group`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse("[]", page: 1, nextPage: 2),
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:40Z"}]"#, page: 2, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            localClock: { .init(timeIntervalSince1970: reference + 3600) }
        )
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: reference))
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: cursor
        )
        #expect(result.cursor == cursor)
        // 有東西越過了游標、卻不在可採信的位置上：不推進，但要出聲。
        #expect(result.completion == .stalled)
    }

    /// 反例配對：第一頁的最大值本來就推得動游標時，一切照常、不算卡住。
    @Test
    func `a normal multi page walk is not a stall`() async throws {
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
            cursor: .init(watermark: .init(timeIntervalSince1970: reference))
        )
        #expect(result.completion == .complete)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: reference + 5))
    }

    /// 反例配對：讀到的資源都還在游標那一秒內時，游標不動是正常的安靜輪次、不是卡住。
    @Test
    func `re reading the boundary second is not a stall`() async throws {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:00.900Z"}]"#, page: 1, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: reference))
        let result: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: cursor
        )
        #expect(result.completion == .complete)
        #expect(result.cursor == cursor)
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

}

private final class ProjectResourcePollerFailureTests {

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

    /// 時間戳解不出來時同樣整頁失敗、不靜默丟掉那一筆（丟掉就等於那個資源從未被偵測到）。
    @Test
    func `unparsable timestamp fails the page`() async {
        let transport: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"yesterday"}]"#, page: 1, nextPage: nil),
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

    /// 解碼失敗要指得出是哪一個欄位：整頁一起解，一筆寫壞就整頁失敗、而且每輪都會再撞一次。
    ///
    /// 「某筆的 `updated_at` 寫壞」與「整包根本不是 JSON」若回一模一樣的錯誤，就沒有任何線索可查。
    @Test
    func `decoding failure names the offending field`() async throws {
        let badField: ScriptedTransport = .init([
            pageResponse(#"[{"id":1,"updated_at":"yesterday"}]"#, page: 1, nextPage: nil),
        ])
        let notJSON: ScriptedTransport = .init([pageResponse("not json", page: 1, nextPage: nil)])
        var messages: [String] = []
        for transport: ScriptedTransport in [badField, notJSON] {
            let poller: ProjectResourcePoller = .init(transport: transport)
            do {
                let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                    host: "https://gitlab.example.com",
                    projectIdentifier: "42",
                    collection: .mergeRequests,
                    privateToken: "synthetic-read-token",
                    cursor: .init()
                )
                Issue.record("解不開的本體應該拋錯")
            } catch let GitLabAPIError.undecodableCollection(detail) {
                messages.append(detail)
            }
        }
        #expect(messages.count == 2)
        // 兩種失敗必須分得出來，且欄位錯誤要指到那個欄位。
        #expect(messages[0] != messages[1])
        #expect(messages[0].contains("updated_at"))
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

    /// 少寫 scheme 但帶埠號的 host 必須擋下。
    ///
    /// 只檢查「有沒有 scheme」擋不住它：`gitlab.example.com:7071` 會被解析成 scheme 為
    /// `gitlab.example.com`、host 為空，於是組出一個送不到任何地方的網址，直到連線層才失敗。
    @Test
    func `host missing its scheme is rejected`() async {
        let transport: ScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                host: "gitlab.example.com:7071",
                projectIdentifier: "42",
                collection: .mergeRequests,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    /// host 帶查詢字串或片段時必須擋下。
    ///
    /// 這類 host 若用字串串接組路徑，整段 `/api/v4/…` 會被吞進查詢或片段裡，
    /// 組出一個打在站台首頁、卻完全不像壞掉的網址——請求會成功、回的是網頁。
    @Test
    func `host carrying a query or fragment is rejected`() async {
        for host: String in ["https://gitlab.example.com?a=b", "https://gitlab.example.com#frag"] {
            let transport: ScriptedTransport = .init([])
            let poller: ProjectResourcePoller = .init(transport: transport)
            await #expect(throws: GitLabAPIError.self) {
                let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                    host: host,
                    projectIdentifier: "42",
                    collection: .issues,
                    privateToken: "synthetic-read-token",
                    cursor: .init()
                )
            }
            #expect(transport.requests.withLock { $0.isEmpty })
        }
    }

    /// host 帶 userinfo 時必須擋下：那會把讀取憑證送到別人家。
    ///
    /// `https://gitlab.example.com@elsewhere.example` 解析後的 host 是 `elsewhere.example`、
    /// 前半段成了使用者名稱——字串看起來像自家站台，`PRIVATE-TOKEN` 標頭卻會連同請求一起送過去。
    @Test
    func `host carrying userinfo is rejected`() async {
        let transport: ScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
                host: "https://gitlab.example.com@elsewhere.example",
                projectIdentifier: "42",
                collection: .issues,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    /// host 帶路徑前綴（反向代理掛在子路徑下）時保留該前綴，且結尾多重斜線一併修掉。
    @Test
    func `host path prefix is preserved and trailing slashes collapse`() async throws {
        let transport: ScriptedTransport = .init([pageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let _: ResourcePollResult<SyntheticResource> = try await poller.poll(
            host: "https://example.com/gitlab//",
            projectIdentifier: "42",
            collection: .issues,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.url.path == "/gitlab/api/v4/projects/42/issues")
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
