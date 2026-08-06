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

private final class ProjectResourcePollerClockTests {

    /// 上限落在未來時，游標**照樣推得動**、本輪照樣 `complete`——上限等於不存在，卻沒有任何跡象。
    ///
    /// 那正是會漏資料的方向：本輪查詢快照之後才提交、時間戳卻更早的資源會沉到水位之下。
    /// 因此這件事不能靠 `completion` 表達（那個列舉在游標動得了時根本不看），改由旗標帶出去。
    @Test
    func `a cap in the future is reported as untrustworthy while the cursor still advances`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:20Z"}]"#,
                page: 1,
                nextPage: nil,
                // 前置代理時鐘快一小時。
                serverDate: "Thu, 06 Aug 2026 10:00:30 GMT"
            ),
        ])
        let frozen: ContinuousClock.Instant = .now
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            clockSkewAllowance: 120,
            localClock: { .init(timeIntervalSince1970: pollReference + 20) },
            monotonicNow: { frozen }
        )
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init(watermark: .init(timeIntervalSince1970: pollReference + 10))
        )
        #expect(result.completion == .complete)
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 20))
        #expect(!result.capIsTrustworthy)
    }

    /// 反例配對：兩邊時鐘對得上時，上限可信。少了這一半就分不出旗標是不是恆為 false。
    @Test
    func `a cap from an agreeing clock is trustworthy`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:20Z"}]"#,
                page: 1,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:00:30 GMT"
            ),
        ])
        let frozen: ContinuousClock.Instant = .now
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            clockSkewAllowance: 120,
            localClock: { .init(timeIntervalSince1970: pollReference + 30) },
            monotonicNow: { frozen }
        )
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init(watermark: .init(timeIntervalSince1970: pollReference + 10))
        )
        #expect(result.capIsTrustworthy)
    }

    /// 時鐘分歧**不得**讓本輪被判成 `stalled`：這個比較分不出是站台錯還是本機錯，
    /// 而本機時鐘偏掉時站台完全正常、下一輪照樣推得動。它只該讓 `capIsTrustworthy` 轉為 `false`。
    @Test
    func `clock disagreement lowers trust without reporting a stall`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:20Z"}]"#,
                page: 1,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:00:05 GMT"
            ),
        ])
        let frozen: ContinuousClock.Instant = .now
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            clockSkewAllowance: 60,
            // 本機時鐘比站台回報的時刻晚一小時，遠超過容差＋逾時。
            localClock: { .init(timeIntervalSince1970: pollReference + 3600) },
            monotonicNow: { frozen }
        )
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: pollReference + 10))
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

    /// 反例配對：上限來自站台 `Date` 標頭而壓住游標時，**不算卡住**。
    ///
    /// 該標頭只有整秒精度、又扣掉了來回耗時，因此系統性地落後真實時刻約一秒；最近一秒內的異動
    /// 本輪推不動、下一輪就推得動。報成 `stalled` 會讓完全正常的站台每有一筆剛發生的異動就誤報一次，
    /// 而這個狀態一旦開始誤報就沒有人會再認真看它。與「時鐘不堪用」那一例只差上限從哪裡來。
    @Test
    func `a blocked cursor under a server clock cap stays complete`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:11.200Z"}]"#,
                page: 1,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:00:10 GMT"
            ),
        ])
        let frozen: ContinuousClock.Instant = .now
        // 本機時鐘必須也釘死：沿用真實牆上時鐘的話，等真實時間走過 fixture 時刻加上容差之後，
        // 「上限與本機時鐘對不對得上」就會翻面，這個測試會從某一刻起永久失敗。
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            localClock: { .init(timeIntervalSince1970: pollReference + 10) },
            monotonicNow: { frozen }
        )
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: pollReference + 10))
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: cursor
        )
        #expect(result.cursor == cursor)
        #expect(result.completion == .complete)
    }

    /// 反例配對：讀到的資源都還在游標那一秒內時，游標不動是正常的安靜輪次、不是卡住。
    @Test
    func `re reading the boundary second is not a stall`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:00.900Z"}]"#, page: 1, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: pollReference))
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:00.900Z"}]"#, page: 1, nextPage: 2),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport, pageBudget: 1)
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
        #expect(result.elements.count == 1)
    }

    /// 游標壓在站台時鐘之下：站台回報的時刻比讀到的資源早時，以站台時刻為準。
    @Test
    func `cursor is capped by the server clock`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:50Z"}]"#,
                page: 1,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:00:30 GMT"
            ),
        ])
        // 凍住單調時鐘讓來回耗時恰為 0，單獨檢驗「以站台時刻封頂」。
        let frozen: ContinuousClock.Instant = .now
        let poller: ProjectResourcePoller = .init(transport: transport, monotonicNow: { frozen })
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 30))
    }

    /// 站台時刻要再往前扣掉那一次來回的耗時。
    ///
    /// `Date` 標頭是**回應產生時**的時刻，晚於查詢取快照的瞬間。直接拿它當上限，上限就比快照晚一整個
    /// 請求的時間；那段期間提交、時間戳卻更早的資料會落在新水位之下、再也讀不回來。
    @Test
    func `walk start subtracts the first round trip from the server clock`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(
                #"[{"id":1,"updated_at":"2026-08-06T09:00:50Z"}]"#,
                page: 1,
                nextPage: nil,
                serverDate: "Thu, 06 Aug 2026 09:00:30 GMT"
            ),
        ])
        // 單調時鐘每次讀取前進 8 秒 → 這次來回耗時量到 8 秒。
        let ticks: Mutex<Int> = .init(0)
        let origin: ContinuousClock.Instant = .now
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            monotonicNow: {
                let tick: Int = ticks.withLock { count in
                    defer { count += 1 }
                    return count
                }
                return origin.advanced(by: .seconds(tick * 8))
            }
        )
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        // 站台回應時刻 09:00:30 減去 8 秒＝09:00:22，早於資源的 09:00:50 → 以它封頂。
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 22))
    }

    /// 站台沒送 `Date` 標頭時退回本機時鐘、並往前扣容差；扣的方向只會造成重讀。
    @Test
    func `missing date header falls back to the local clock minus the allowance`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:09:00Z"}]"#, page: 1, nextPage: nil, serverDate: nil),
        ])
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            clockSkewAllowance: 120,
            localClock: { .init(timeIntervalSince1970: pollReference + 600) }
        )
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .mergeRequests,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        // 本機時鐘 09:10:00 扣 120 秒＝09:08:00，早於資源的 09:09:00 → 以容差後的時刻封頂。
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference + 480))
        // 沒有站台時鐘可對，上限完全建立在本機時鐘上——無從查核，一律不可信。
        #expect(!result.capIsTrustworthy)
    }

    /// 空集合不推進游標：沒讀到東西不代表那段時間沒有東西被改過。
    @Test
    func `empty result does not advance the cursor`() async throws {
        let transport: PollScriptedTransport = .init([pollPageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: pollReference))
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([.init(statusCode: 401)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.unexpectedStatus(401)) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([pollPageResponse("not json", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"yesterday"}]"#, page: 1, nextPage: nil),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let badField: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"yesterday"}]"#, page: 1, nextPage: nil),
        ])
        let notJSON: PollScriptedTransport = .init([pollPageResponse("not json", page: 1, nextPage: nil)])
        var messages: [String] = []
        for transport: PollScriptedTransport in [badField, notJSON] {
            let poller: ProjectResourcePoller = .init(transport: transport)
            do {
                let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([
            .init(statusCode: 200, body: .init("[]".utf8), headers: ["X-Next-Page": "2"]),
        ])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
    /// `gitlab.example.com:7071` 會被解析成 scheme 為 `gitlab.example.com`、host 為 nil；
    /// 守衛鏈先判 scheme，所以**攔下它的是白名單**（`gitlab.example.com` 不在其中）。
    /// 主機名那道守衛負責的是另一種形狀——scheme 合法、主機名卻是空的，見 `https:///gitlab` 那例。
    @Test
    func `host missing its scheme is rejected`() async {
        let transport: PollScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
            let transport: PollScriptedTransport = .init([])
            let poller: ProjectResourcePoller = .init(transport: transport)
            await #expect(throws: GitLabAPIError.self) {
                let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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

    /// 錯誤訊息不得帶原始網址：`https://oauth2:<token>@host` 是合法輸入，
    /// 原樣放進錯誤就等於把憑證寫進每一行 log——那道守衛本來是要保護憑證的。
    @Test
    func `rejection never echoes credentials from the host`() async {
        let secret: String = "synthetic-token-value"
        let transport: PollScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        do {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
                host: "https://oauth2:\(secret)@gitlab.example.com",
                projectIdentifier: "42",
                collection: .issues,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
            Issue.record("帶 userinfo 的 host 應該被擋下")
        } catch let GitLabAPIError.invalidURL(location) {
            #expect(!location.contains(secret))
            #expect(!location.contains("oauth2"))
            // 仍要指得出是哪個站台，否則錯誤訊息沒有查的價值。
            #expect(location == "https://gitlab.example.com")
        } catch {
            Issue.record("預期 invalidURL，實得 \(error)")
        }
    }

    /// 空專案識別字會組出 `/projects//issues`——請求照樣帶著憑證送出、站台回 404，
    /// 呼叫端看到的是「查無此專案」而不是「參數沒填」。必須在送出前擋掉。
    @Test
    func `empty project identifier is rejected before any request`() async {
        let transport: PollScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
                host: "https://gitlab.example.com",
                projectIdentifier: "",
                collection: .issues,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    /// 沒有主機名的網址（設定檔少打一段）必須擋下，而不是組出一個打不到任何地方的請求。
    @Test
    func `host without a hostname is rejected`() async {
        let transport: PollScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
                host: "https:///gitlab",
                projectIdentifier: "42",
                collection: .issues,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    /// scheme 白名單必須真的擋得住非 HTTP scheme。
    ///
    /// `ftp://gitlab.example.com` 寫得出主機名、通得過主機名那道守衛；白名單一旦放寬成「有 scheme
    /// 就好」，它就會帶著 `PRIVATE-TOKEN` 一路交給傳輸層。
    @Test
    func `non http scheme is rejected`() async {
        let transport: PollScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
                host: "ftp://gitlab.example.com",
                projectIdentifier: "42",
                collection: .issues,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
        }
        #expect(transport.requests.withLock { $0.isEmpty })
    }

    /// 連 scheme 都漏打時（設定檔常見），錯誤訊息**不得回退成原字串**——那字串可能整段帶著憑證。
    @Test
    func `unparsable host falls back to a fixed description`() async {
        let secret: String = "synthetic-token-value"
        let transport: PollScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        do {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
                host: "oauth2:\(secret)@gitlab.example.com",
                projectIdentifier: "42",
                collection: .issues,
                privateToken: "synthetic-read-token",
                cursor: .init()
            )
            Issue.record("解不出主機名的 host 應該被擋下")
        } catch let GitLabAPIError.invalidURL(location) {
            #expect(!location.contains(secret))
            #expect(!location.contains("gitlab.example.com"))
        } catch {
            Issue.record("預期 invalidURL，實得 \(error)")
        }
    }

    /// 時鐘容差的下界必須夾住：負值會讓上限落到**未來**，本輪快照之後才提交、時間戳卻更早的資料
    /// 就此沉到水位之下——正是這道上限存在要擋的那種無聲漏讀。
    @Test
    func `clock skew allowance is clamped from below`() async throws {
        let transport: PollScriptedTransport = .init([
            pollPageResponse(#"[{"id":1,"updated_at":"2026-08-06T09:00:20Z"}]"#, page: 1, nextPage: nil, serverDate: nil),
        ])
        let poller: ProjectResourcePoller = .init(
            transport: transport,
            clockSkewAllowance: -300,
            localClock: { .init(timeIntervalSince1970: pollReference) }
        )
        #expect(poller.clockSkewAllowance == 0)
        let result: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .issues,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        // 夾住之後上限＝本機時刻本身（09:00:00），不會落到未來的 09:05:00。
        #expect(result.cursor.watermark == Date(timeIntervalSince1970: pollReference))
    }

    /// 專案識別字含 `.`／`..` 必須擋下：正規化後 `/projects/../issues` 會變成 `/issues`，
    /// 站台照收、回的是憑證看得到的所有專案——查詢範圍被無聲換掉，而且不是錯誤。
    @Test
    func `project identifier with dot segments is rejected`() async {
        for identifier: String in ["..", ".", "synthetic-group/.."] {
            let transport: PollScriptedTransport = .init([])
            let poller: ProjectResourcePoller = .init(transport: transport)
            await #expect(throws: GitLabAPIError.self) {
                let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
                    host: "https://gitlab.example.com",
                    projectIdentifier: identifier,
                    collection: .issues,
                    privateToken: "synthetic-read-token",
                    cursor: .init()
                )
            }
            #expect(transport.requests.withLock { $0.isEmpty })
        }
    }

    /// 每頁筆數的下界必須夾住：`per_page=0` 會讓站台每頁都回空陣列且沒有下一頁，
    /// 於是游標永不推進、而每輪都回報 `complete`——一個永遠讀不到東西卻自稱正常的輪詢器。
    @Test
    func `page size and page budget are clamped from below`() async throws {
        let transport: PollScriptedTransport = .init([pollPageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport, pageSize: 0, pageBudget: 0)
        #expect(poller.pageSize == 1)
        #expect(poller.pageBudget == 1)
        let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
            host: "https://gitlab.example.com",
            projectIdentifier: "42",
            collection: .issues,
            privateToken: "synthetic-read-token",
            cursor: .init()
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(pollQueryItems(of: request)["per_page"] == "1")
    }

    /// host 帶 userinfo 時必須擋下：那會把讀取憑證送到別人家。
    ///
    /// `https://gitlab.example.com@elsewhere.example` 解析後的 host 是 `elsewhere.example`、
    /// 前半段成了使用者名稱——字串看起來像自家站台，`PRIVATE-TOKEN` 標頭卻會連同請求一起送過去。
    @Test
    func `host carrying userinfo is rejected`() async {
        let transport: PollScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([pollPageResponse("[]", page: 1, nextPage: nil)])
        let poller: ProjectResourcePoller = .init(transport: transport)
        let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
        let transport: PollScriptedTransport = .init([])
        let poller: ProjectResourcePoller = .init(transport: transport)
        await #expect(throws: GitLabAPIError.self) {
            let _: ResourcePollResult<PollSyntheticResource> = try await poller.poll(
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
