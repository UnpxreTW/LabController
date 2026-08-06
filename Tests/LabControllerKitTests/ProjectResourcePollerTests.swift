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

private final class ProjectResourcePollerTests {

    /// 請求形狀：GET、路徑、排序與翻頁參數、憑證放在 `PRIVATE-TOKEN` 標頭。
    @Test
    func `poll issues a get with the ordering the cursor depends on`() async throws {
        let transport: PollScriptedTransport = .init([pollPageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init(watermark: .init(timeIntervalSince1970: pollReference))
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.method == "GET")
        #expect(request.url.path == "/api/v4/projects/42/merge_requests")
        #expect(request.headers["PRIVATE-TOKEN"] == "synthetic-read-token")
        let items: [String: String] = pollQueryItems(of: request)
        #expect(items["order_by"] == "updated_at")
        #expect(items["sort"] == "asc")
        #expect(items["per_page"] == "100")
        #expect(items["page"] == "1")
        #expect(items["updated_after"] == "2026-08-06T09:00:00Z")
        // 這類查詢應快速失敗；不給逾時會靜默沿用 URLSession 的預設，與宣告的行為相反。
        #expect(request.timeout == ProjectResourcePoller.requestTimeout)
    }

    /// 首輪（游標未設）不帶 `updated_after`，代表讀全集。
    @Test
    func `first poll omits the updated after filter`() async throws {
        let transport: PollScriptedTransport = .init([pollPageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com/",
            projectIdentifier: "42",
            collection: .issues,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(pollQueryItems(of: request)["updated_after"] == nil)
        // host 結尾的斜線也一併修剪、不產生 //api 路徑。
        #expect(request.url.path == "/api/v4/projects/42/issues")
    }

    /// 以完整路徑指定專案時，斜線必須編碼成 `%2F`，否則會被當成多一層路徑而打到不存在的端點。
    @Test
    func `project path is percent encoded`() async throws {
        let transport: PollScriptedTransport = .init([pollPageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([pollPageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport, pageSize: 500)
        #expect(poller.pageSize == ProjectResourcePoller.maximumPageSize)
        let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(pollQueryItems(of: request)["per_page"] == "100")
    }

    /// 多頁走完：資源依序串起、翻頁靠 `X-Next-Page` 而非筆數，最後一頁的空字串即終止。
    @Test
    func `walk follows next page header until it is empty`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05.250Z"}]"#, page: 1, nextPage: 2),
            pollPageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:10Z"}]"#, page: 2, nextPage: 3),
            pollPageResponse(#"[{"id":3,"updated_at":"2026-08-06T09:00:20.750Z"}]"#, page: 3, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 3)
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
            .init(timeIntervalSince1970: pollReference + 5.25),
            .init(timeIntervalSince1970: pollReference + 10),
            .init(timeIntervalSince1970: pollReference + 20.75),
        ])
        let pages: [String?] = transport.requests.withLock { $0.map { pollQueryItems(of: $0)["page"] } }
        #expect(pages == ["1", "2", "3"])
    }

}

private final class ProjectResourcePollerCursorTests {

    /// 單頁走完：第一頁就是全部，游標推到讀到的最大時刻——穩定運轉時的常態，推進毫無損失。
    @Test
    func `single page walk advances to the newest resource seen`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"},{"id":2,"updated_at":"2026-08-06T09:00:20Z"}]"#,
                page: 1,
                nextPage: nil
            ),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.completion == .complete)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 20))
    }

    /// 多頁走完：即使走到最後一頁、即使全部資源都早於本輪起始時刻，游標仍只推到**第一頁**的最大時刻。
    ///
    /// 第二頁以後不能採信：翻頁途中若有資源被刪除或改動，後面的資源會整體前移而跨過已讀邊界，
    /// 且刪除不留任何新時間戳、無從偵測。上一例（單頁）證明推進得動，本例證明多頁時確實只採信第一頁。
    @Test
    func `multi page walk advances only to the first page maximum`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"}]"#, page: 1, nextPage: 2),
            pollPageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:20Z"}]"#, page: 2, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 2)
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.completion == .complete)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 5))
        // 資源本身照樣全數交出去，保守的只有游標。
        #expect(result.elements.map(\.identifier) == [1, 2])
    }

    /// 撞到翻頁預算時同樣只推第一頁。
    ///
    /// 預算刻意設 2 並讓第二頁的最大時刻晚於第一頁：若規則被改成「推到最後讀到的那頁」，本例會抓到，
    /// 單頁的截斷案例則抓不到（那時兩者相等）。
    @Test
    func `hitting the page budget advances only to the first page maximum`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"}]"#, page: 1, nextPage: 2),
            pollPageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:20Z"}]"#, page: 2, nextPage: 3),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 2)
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.completion == .truncated)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 5))
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
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:30Z"}]"#,
                page: 1,
                nextPage: 2,
                serverDate: "Thu, 06 Aug 2026 09:00:10 GMT"
            ),
            pollPageResponse(
                #"[{"id":2,"updated_at":"2026-08-06T09:00:40Z"}]"#,
                page: 2,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:01:00 GMT"
            ),
        ])
        // 凍住單調時鐘讓來回耗時恰為 0，把「起始時刻取自哪個回應」單獨隔離出來檢驗。
        let frozen: ContinuousClock.Instant = .now
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            pageBudget: 2,
            monotonicNow: { frozen }
        )
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 10))
    }

    /// 有東西可推進、卻被上限壓住而動不了，同樣是會自我重複的狀態，即使沒撞到翻頁預算也要報 `stalled`。
    ///
    /// 場景：站台沒送 `Date` 標頭、本機時鐘又落後站台一小時 → 起始時刻早於所有資源 → 游標推不動。
    ///
    /// 這件事**不報成 `stalled`**：本輪看不出它會不會自己好（時鐘走著走著上限就追上來了），
    /// 而 `stalled` 的語義是「不會自己好」。改由 `capIsTrustworthy` 表達「這一輪的上限別當保護」。
    @Test
    func `an unusable clock lowers trust without claiming the round will repeat`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:20Z"}]"#, page: 1, nextPage: nil, serverDate: nil),
        ])
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            localClock: { .init(timeIntervalSince1970: pollReference - 3600) }
        )
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: pollReference))
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: cursor
        )
        #expect(result.cursor == cursor)
        #expect(!result.capIsTrustworthy)
        #expect(result.completion != .stalled)
    }

    /// 同一秒的資源塞滿第一頁時，游標推不動——**不自作主張跨過去**，改回報 `stalled`。
    ///
    /// 跨過去需要「那一秒已讀完」的證據，而唯一的來源是第二頁以後；站台對 `updated_at` 沒有第二排序鍵，
    /// 時間戳相同的資源在不同次請求之間順序未定，所以那個證據推論不成立。照它跨過去，
    /// 沒露過面的同時刻資源就此沉到水位之下、永遠讀不到。卡住則一筆都沒丟。
    @Test
    func `an oversized tie group on the first page stalls instead of being crossed`() async throws {
        // 預設預算為 1，這裡要讀到第二頁才驗得到「讀完了也照樣不推進」。
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:00.100Z"},{"id":2,"updated_at":"2026-08-06T09:00:00.900Z"}]"#,
                page: 1,
                nextPage: 2
            ),
            pollPageResponse(
                #"[{"id":3,"updated_at":"2026-08-06T09:00:20Z"},{"id":4,"updated_at":"2026-08-06T09:00:25Z"}]"#,
                page: 2,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:01:00 GMT"
            ),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 2)
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: pollReference))
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:00.100Z"}]"#, page: 1, nextPage: 2),
            pollPageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:00.900Z"}]"#, page: 2, nextPage: 3),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 2)
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: pollReference))
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([
            pollPageResponse("[]", page: 1, nextPage: 2),
            // 第二頁那筆的時刻不影響結果——輪詢器不看第二頁以後的時間戳。留在游標那一秒內是為了
            // 讓 fixture 只表達「第一頁是空的、後面還有頁」這一件事。
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:00.500Z"}]"#, page: 2, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            pageBudget: 2,
            localClock: { .init(timeIntervalSince1970: pollReference + 3600) }
        )
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: pollReference))
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:05Z"}]"#, page: 1, nextPage: 2),
            pollPageResponse(#"[{"id":2,"updated_at":"2026-08-06T09:00:20Z"}]"#, page: 2, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 2)
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init(watermark: .init(timeIntervalSince1970: pollReference))
        )
        #expect(result.completion == .complete)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 5))
    }

}
