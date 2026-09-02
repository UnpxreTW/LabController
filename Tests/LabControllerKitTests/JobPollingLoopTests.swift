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

/// 站台此刻連不上；只用來排「這一次領不到」的那一步。
private struct TransportOutage: Error {}

/// 送出去的那條網址把憑證嵌在 userinfo 段；全為合成值。
private let credentialBearingURL: String = "https://oauth2:glpat-synthetic@gitlab.example.invalid/api/v4/jobs/request"

/// `URLSession` 連不上時實際會拋的形狀：`userInfo` 原樣帶著送出去的整條網址。
///
/// 假傳輸原本只拋合成型別 ``TransportOutage``，永遠碰不到這條真路徑，遮蔽漏了也測不出來。
private let credentialBearingTransportError: URLError = {
    guard let url: URL = .init(string: credentialBearingURL) else { preconditionFailure("合成網址字面值應解得開") }
    return .init(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
}()

/// 依序播放的假傳輸，序列裡可以排連不上的那一次。
///
/// 全部為合成資料（假 id／token／站台位址）。序列耗盡後重複最後一步——迴圈要跑幾輪由測試的
/// 停止條件決定，回應不必預先數好準備幾份。
private final class ScriptedPollTransport: HTTPTransport, Sendable {

    /// 一次呼叫要發生什麼。
    enum Step: Sendable {

        /// 回這個回應。
        case respond(HTTPResponse)

        /// 這一次連不上。
        case fail

        /// 這一次連不上，且拋的是把網址帶在身上的真 `URLError`。
        case failWithCredentialBearingURL
    }

    /// 收到的請求，依序累積。
    let requests: Mutex<[HTTPRequest]> = .init([])

    /// 待播放的步驟序列。
    private let steps: Mutex<[Step]>

    /// 以步驟序列建立。
    ///
    /// - Parameter steps: 依序播放的步驟。
    init(_ steps: [Step]) {
        self.steps = .init(steps)
    }

    /// 記錄請求，播放序列中的下一步。
    ///
    /// - Parameter request: 送出的請求。
    /// - Returns: 這一步排定的回應。
    /// - Throws: 這一步排的是連不上時拋 ``TransportOutage``，排的是帶網址那形時拋 `URLError`。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.withLock { $0.append(request) }
        let step: Step = steps.withLock { queue in
            queue.count > 1 ? queue.removeFirst() : (queue.first ?? .fail)
        }
        switch step {
        case let .respond(response): return response
        case .fail: throw TransportOutage()
        case .failWithCredentialBearingURL: throw credentialBearingTransportError
        }
    }
}

/// 從請求本體解出 JSON 物件；解不出即測試失敗。
private func requestBody(of request: HTTPRequest) throws -> [String: Any] {
    let data: Data = try #require(request.body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// 站台指派一件 job 的回應；全為合成值。
private let assignedJob: HTTPResponse = .init(
    statusCode: 201,
    body: .init(#"""
    {"id":7,"token":"synthetic-job-token",
     "steps":[{"name":"script","script":["swift build"],"allow_failure":false}],
     "git_info":{"repo_url":"https://example.invalid/g/a.git","ref":"main","sha":"deadbeef"}}
    """#.utf8)
)

/// 站台指派一件本 executor 收不下的 job（宣告要在容器裡跑）。
private let containerJob: HTTPResponse = .init(
    statusCode: 201,
    body: .init(#"""
    {"id":9,"token":"synthetic-job-token","image":{"name":"ruby:3.2"},
     "steps":[{"name":"script","script":["ruby -v"],"allow_failure":false}]}
    """#.utf8)
)

/// 測試共用的迴圈設定；站台位址與 token 皆為合成值。
private let configuration: JobPollingLoop.Configuration = .init(
    host: "https://gitlab.example.invalid",
    runnerToken: "synthetic-runner-token",
    image: .alias("golden-xcode")
)

private final class JobPollingLoopTests {

    /// 領到就跑完、回寫，處置帶著 job 識別碼與結果類別。
    @Test
    func `runs an assigned job and reports the outcome`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(assignedJob), .respond(.init(statusCode: 200))])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration
        )
        let cycle: JobCycle = try await loop.poll(cursor: nil)
        #expect(cycle.disposition == .handled(jobIdentifier: 7, outcome: .completed, delivery: .init(
            acceptance: .written, traceIsComplete: true, updateAttempts: 1
        )))
        #expect(cycle.didHandleJob)
    }

    /// 兩把 token 各走各的：領件帶 runner 認證 token、回寫一律帶站台隨該件 job 發的專屬 token。
    @Test
    func `keeps the runner token out of the reporting path`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(assignedJob), .respond(.init(statusCode: 200))])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration
        )
        _ = try await loop.poll(cursor: nil)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        #expect(try requestBody(of: requests[0])["token"] as? String == "synthetic-runner-token")
        let trace: HTTPRequest = try #require(requests.first { $0.method == "PATCH" })
        #expect(trace.headers["JOB-TOKEN"] == "synthetic-job-token")
        let update: HTTPRequest = try #require(requests.last)
        #expect(update.method == "PUT")
        #expect(try requestBody(of: update)["token"] as? String == "synthetic-job-token")
        // 領件之後的每一個請求，不論標頭或本體，都不該再出現 runner 認證 token。
        let leaked: Bool = requests.dropFirst().contains { request in
            let body: String = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return body.contains("synthetic-runner-token")
                || request.headers.values.contains("synthetic-runner-token")
        }
        #expect(!leaked)
    }

    /// 沒領到也要把游標帶回來——long-poll 的 hold 就是靠它，漏帶等於每一輪都白等。
    @Test
    func `carries the cursor forward when no job is available`() async throws {
        let transport: ScriptedPollTransport = .init([
            .respond(.init(statusCode: 204, headers: ["X-GitLab-Last-Update": "cursor-2"])),
        ])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            configuration: configuration
        )
        let cycle: JobCycle = try await loop.poll(cursor: "cursor-1")
        #expect(cycle.disposition == .idle)
        #expect(cycle.cursor == "cursor-2")
        #expect(!cycle.didHandleJob)
        let poll: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(try requestBody(of: poll)["last_update"] as? String == "cursor-1")
    }

    /// 收不下的 payload 當面拒收：站台端收到的是「程式錯、不重試」，且拒收理由已寫進 trace。
    @Test
    func `refuses a job it cannot digest and writes the reason back`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(containerJob), .respond(.init(statusCode: 200))])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration
        )
        let cycle: JobCycle = try await loop.poll(cursor: nil)
        #expect(cycle.disposition == .refused(jobIdentifier: 9, delivery: .init(
            acceptance: .written, traceIsComplete: true, updateAttempts: 1
        )))
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        let trace: HTTPRequest = try #require(requests.first { $0.method == "PATCH" })
        let traceBody: Data = try #require(trace.body)
        #expect(String(decoding: traceBody, as: UTF8.self).contains("ruby:3.2"))
        let last: HTTPRequest = try #require(requests.last)
        let update: [String: Any] = try requestBody(of: last)
        #expect(update["state"] as? String == "failed")
        #expect(update["failure_reason"] as? String == "script_failure")
    }

    /// 拒收沒開過任何執行環境——擋在執行之前才省得下那一格。
    @Test
    func `spawns nothing for a refused job`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let transport: ScriptedPollTransport = .init([.respond(containerJob), .respond(.init(statusCode: 200))])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: backend,
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration
        )
        _ = try await loop.poll(cursor: nil)
        #expect(backend.destroyCount == 0)
        #expect(try await backend.ps().isEmpty)
    }

    /// `--once`：經手完一件就收工，不再敲下一輪。
    @Test
    func `stops after the first handled job when asked to`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(assignedJob), .respond(.init(statusCode: 200))])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration
        )
        let lines: Mutex<[String]> = .init([])
        await loop.run(stopAfterFirstJob: true, isStopped: { false }, log: { line in
            lines.withLock { $0.append(line) }
        })
        let polls: [HTTPRequest] = transport.requests.withLock { $0.filter { $0.url.lastPathComponent == "request" } }
        #expect(polls.count == 1)
        #expect(lines.withLock { $0 }.count == 1)
    }

    /// 領件失敗不結束迴圈：退開設定的秒數再試，下一輪照常領件。
    @Test
    func `backs off and keeps polling after a failed request`() async throws {
        let transport: ScriptedPollTransport = .init([
            .fail, .respond(assignedJob), .respond(.init(statusCode: 200)),
        ])
        let waits: Mutex<[TimeInterval]> = .init([])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration,
            wait: { seconds in waits.withLock { $0.append(seconds) } }
        )
        let lines: Mutex<[String]> = .init([])
        await loop.run(stopAfterFirstJob: true, isStopped: { false }, log: { line in
            lines.withLock { $0.append(line) }
        })
        #expect(waits.withLock { $0 } == [30])
        #expect(lines.withLock { $0.first }?.hasPrefix("poll failed") == true)
        let polls: [HTTPRequest] = transport.requests.withLock { $0.filter { $0.url.lastPathComponent == "request" } }
        #expect(polls.count == 2)
    }

    /// 領件失敗那一行不帶憑證：傳輸層的錯誤把整條網址帶在身上，而站台位址收得下憑證。
    @Test
    func `keeps credentials out of the line logged for a failed request`() async throws {
        let transport: ScriptedPollTransport = .init([.failWithCredentialBearingURL, .respond(assignedJob)])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration,
            wait: { _ in }
        )
        let lines: Mutex<[String]> = .init([])
        await loop.run(stopAfterFirstJob: true, isStopped: { false }, log: { line in
            lines.withLock { $0.append(line) }
        })
        let first: String = try #require(lines.withLock { $0.first })
        #expect(first.hasPrefix("poll failed"))
        #expect(!first.contains("glpat-synthetic"))
        #expect(first.contains("https://gitlab.example.invalid"))
    }

    /// 回寫失敗那一行同樣不帶憑證：兩條錯誤路徑走同一套收斂。
    @Test
    func `keeps credentials out of the line logged for an undeliverable report`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(assignedJob), .failWithCredentialBearingURL])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration,
            wait: { _ in }
        )
        let lines: Mutex<[String]> = .init([])
        await loop.run(stopAfterFirstJob: true, isStopped: { false }, log: { line in
            lines.withLock { $0.append(line) }
        })
        let first: String = try #require(lines.withLock { $0.first })
        #expect(first.hasPrefix("job 7 report failed"))
        #expect(!first.contains("glpat-synthetic"))
        #expect(first.contains("https://gitlab.example.invalid"))
    }

    /// 回寫第一次送不出去就重送一次；送到了照樣是「經手完一件」。
    @Test
    func `resends the report once when the first attempt fails`() async throws {
        let transport: ScriptedPollTransport = .init([
            .respond(assignedJob), .fail, .respond(.init(statusCode: 200)),
        ])
        let waits: Mutex<[TimeInterval]> = .init([])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration,
            wait: { seconds in waits.withLock { $0.append(seconds) } }
        )
        let cycle: JobCycle = try await loop.poll(cursor: nil)
        #expect(waits.withLock { $0 } == [30])
        #expect(cycle.disposition == .handled(jobIdentifier: 7, outcome: .completed, delivery: .init(
            acceptance: .written, traceIsComplete: true, updateAttempts: 1
        )))
    }

    /// 回寫兩次都送不出去：拋的是帶著 job 識別碼的錯，不是領件那一種。
    @Test
    func `reports which job could not be delivered`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(assignedJob), .fail])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration,
            wait: { _ in }
        )
        await #expect(throws: JobDeliveryFailure.self) {
            _ = try await loop.poll(cursor: nil)
        }
    }

    /// `--once` 遇上回寫失敗照樣收工：那件 job 已經跑過，再領第二件等於同機疊工作。
    @Test
    func `stops after a handled job even when the report cannot be delivered`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(assignedJob), .fail])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration,
            wait: { _ in }
        )
        let lines: Mutex<[String]> = .init([])
        await loop.run(stopAfterFirstJob: true, isStopped: { false }, log: { line in
            lines.withLock { $0.append(line) }
        })
        let polls: [HTTPRequest] = transport.requests.withLock { $0.filter { $0.url.lastPathComponent == "request" } }
        #expect(polls.count == 1)
        #expect(lines.withLock { $0 } == ["job 7 report failed: TransportOutage()"])
    }

    /// 拒收那一路的回寫失敗走同一條路：一樣指名 job、一樣讓 `--once` 收工。
    @Test
    func `treats an undeliverable refusal as a handled job`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(containerJob), .fail])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            reporter: .init(client: .init(transport: transport), wait: { _ in }),
            configuration: configuration,
            wait: { _ in }
        )
        let lines: Mutex<[String]> = .init([])
        await loop.run(stopAfterFirstJob: true, isStopped: { false }, log: { line in
            lines.withLock { $0.append(line) }
        })
        #expect(lines.withLock { $0.first }?.hasPrefix("job 9 report failed") == true)
    }

    /// 已經被喊停就一次都不敲——停止旗標在每一輪開始前問。
    @Test
    func `does not poll once stopped`() async throws {
        let transport: ScriptedPollTransport = .init([.respond(assignedJob)])
        let loop: JobPollingLoop = .init(
            client: .init(transport: transport),
            backend: InMemoryExecutionBackend(),
            configuration: configuration
        )
        await loop.run(stopAfterFirstJob: false, isStopped: { true }, log: { _ in })
        #expect(transport.requests.withLock { $0.isEmpty })
    }
}
