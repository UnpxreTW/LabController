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

/// 依序播放預錄回應的假傳輸；記錄所有請求供斷言。
///
/// 全部為合成資料（假 id／token／專案路徑），不含任何真實站台內容。
private final class ScriptedTransport: HTTPTransport, Sendable {

    /// 收到的請求，依序累積。
    let requests: Mutex<[HTTPRequest]> = .init([])

    /// 待播放的回應序列；每次 `send` 取用一個。
    private let responses: Mutex<[HTTPResponse]>

    /// 以回應序列建立。
    init(_ responses: [HTTPResponse]) {
        self.responses = .init(responses)
    }

    /// 記錄請求後回覆序列中的下一個回應；序列耗盡則重複最後一個。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.withLock { $0.append(request) }
        return responses.withLock { queue in
            queue.count > 1 ? queue.removeFirst() : (queue.first ?? .init(statusCode: 500))
        }
    }
}

/// 從請求本體解出 JSON 物件；解不出即測試失敗。（兩個 suite 共用）
private func jsonBody(of request: HTTPRequest) throws -> [String: Any] {
    let data: Data = try #require(request.body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// 領 job（`POST /api/v4/jobs/request`）的協議行為。
private final class JobRequestClientTests {

    /// 201：解出 job、游標取自回應標頭、請求打在 `POST {host}/api/v4/jobs/request`。
    @Test
    func `requestJob decodes assigned job on 201`() async throws {
        let body: Data = .init(#"""
        {"id":7,"token":"synthetic-job-token",
         "variables":[{"key":"CI_PROJECT_PATH","value":"group/app","masked":false}],
         "steps":[{"name":"script","script":["echo hi"],"allow_failure":false}],
         "git_info":{"repo_url":"https://example.invalid/g/a.git","ref":"main","sha":"deadbeef"},
         "artifacts":[{"name":"ignored"}]}
        """#.utf8)
        // 16.2 的 201 分支不發 X-GitLab-Last-Update（只有 204 分支發）、fixture 照實不帶。
        let transport: ScriptedTransport = .init([.init(statusCode: 201, body: body)])
        let client: JobRequestClient = .init(transport: transport)
        let result: JobRequestResult = try await client.requestJob(
            host: "https://gitlab.example.invalid",
            token: "synthetic-runner-token",
            lastUpdate: "cursor-kept"
        )
        guard case let .assigned(job) = result.outcome else {
            Issue.record("預期 assigned、實得 \(result.outcome)")
            return
        }
        #expect(job.id == 7)
        #expect(job.token == "synthetic-job-token")
        #expect(job.variables.first?.key == "CI_PROJECT_PATH")
        #expect(job.steps.first?.script == ["echo hi"])
        #expect(job.gitInfo?.sha == "deadbeef")
        // 201 不發新游標 → 必須沿用傳入值，不得覆寫成 nil（否則 long-poll 從此失效）。
        #expect(result.lastUpdate == "cursor-kept")
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://gitlab.example.invalid/api/v4/jobs/request")
    }
    /// 未知欄位（artifacts／cache／services）不得造成解碼失敗——本片跳過這些能力、
    /// 但站台端仍會回，容錯忽略是刻意行為。
    @Test
    func `requestJob tolerates unknown payload fields`() async throws {
        let body: Data = .init(#"""
        {"id":1,"token":"t","cache":[{"key":"k"}],"services":[{"name":"svc"}],
         "job_info":{"name":"build"},"unknown_future_field":123}
        """#.utf8)
        let transport: ScriptedTransport = .init([.init(statusCode: 201, body: body)])
        let client: JobRequestClient = .init(transport: transport)
        let result: JobRequestResult = try await client.requestJob(host: "https://h.invalid", token: "t")
        guard case let .assigned(job) = result.outcome else {
            Issue.record("預期 assigned")
            return
        }
        #expect(job.id == 1)
        #expect(job.variables.isEmpty)
        #expect(job.gitInfo == nil)
    }
    /// 204：屬正常路徑非錯誤，且**游標一樣要更新**（不是只有 201 才更新）。
    @Test
    func `requestJob treats 204 as no job and still updates cursor`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 204, headers: ["X-GitLab-Last-Update": "cursor-2"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let result: JobRequestResult = try await client.requestJob(host: "https://h.invalid", token: "t")
        #expect(result.outcome == .noJob)
        #expect(result.lastUpdate == "cursor-2")
    }
    /// 游標必須放進 **JSON body** 的 `last_update`。
    ///
    /// Workhorse 的 RegisterHandler 從 body 取這個欄位決定要不要 hold 連線；放在請求
    /// 標頭它讀不到、會直接 proxy 給 Rails 秒回，long-poll 等於沒開（真機才會炸）。
    @Test
    func `requestJob sends last update in body not header`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 204)])
        let client: JobRequestClient = .init(transport: transport)
        _ = try await client.requestJob(host: "https://h.invalid", token: "t", lastUpdate: "prev-cursor")
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.headers["X-GitLab-Last-Update"] == nil)
        let payload: [String: Any] = try jsonBody(of: request)
        #expect(payload["last_update"] as? String == "prev-cursor")
    }
    /// 能力宣告必須進 body 的 `info.features`。
    ///
    /// 站台指派前檢查 `supported_runner?`，不符即 `build.drop!(runner_unsupported)`
    /// ——未宣告 refspecs 時 merge request pipeline 的 job 一被領走就直接判死。
    @Test
    func `requestJob declares runner features in info`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 204)])
        let client: JobRequestClient = .init(transport: transport)
        _ = try await client.requestJob(
            host: "https://h.invalid",
            token: "t",
            info: .init(features: .init(refspecs: true, returnExitCode: true))
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        let payload: [String: Any] = try jsonBody(of: request)
        let info: [String: Any] = try #require(payload["info"] as? [String: Any])
        let features: [String: Any] = try #require(info["features"] as? [String: Any])
        #expect(features["refspecs"] as? Bool == true)
        #expect(features["return_exit_code"] as? Bool == true)
        #expect(features["upload_multiple_artifacts"] as? Bool == false)
    }
    /// long-poll 的逾時必須大於站台 hold 的時間（約 50 秒），否則自己先斷。
    @Test
    func `requestJob uses long poll timeout above server hold`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 204)])
        let client: JobRequestClient = .init(transport: transport)
        _ = try await client.requestJob(host: "https://h.invalid", token: "t")
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        let timeout: TimeInterval = try #require(request.timeout)
        #expect(timeout > 50)
        #expect(timeout == JobRequestClient.jobRequestTimeout)
    }
    /// 非 201／204 一律以狀態碼錯誤拋出。
    @Test
    func `requestJob throws on unexpected status`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 403)])
        let client: JobRequestClient = .init(transport: transport)
        await #expect(throws: GitLabAPIError.unexpectedStatus(403)) {
            _ = try await client.requestJob(host: "https://h.invalid", token: "t")
        }
    }
    /// 201 但本體解不出 → 明確回報解碼失敗，不吞成「無 job」。
    @Test
    func `requestJob throws on undecodable body`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 201, body: .init("not json".utf8))
        ])
        let client: JobRequestClient = .init(transport: transport)
        await #expect(throws: GitLabAPIError.undecodableBody(codingPath: "")) {
            _ = try await client.requestJob(host: "https://h.invalid", token: "t")
        }
    }

    /// 缺必要欄位時要說出是哪一個——「body 解不開」單獨一句話查不動。
    @Test
    func `undecodable body carries the failing key`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 201, body: .init(#"{"token":"synthetic-job-token"}"#.utf8))
        ])
        let client: JobRequestClient = .init(transport: transport)
        await #expect(throws: GitLabAPIError.undecodableBody(codingPath: "id")) {
            _ = try await client.requestJob(host: "https://h.invalid", token: "t")
        }
    }
    /// 每次呼叫只該發一個請求——避免重試錯置／重入被測試放過。
    @Test
    func `each call emits exactly one request`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 204)])
        let client: JobRequestClient = .init(transport: transport)
        _ = try await client.requestJob(host: "https://h.invalid", token: "t")
        #expect(transport.requests.withLock { $0.count } == 1)
    }
    /// host 結尾多餘斜線要修剪，避免組出 `//api/v4`。
    @Test
    func `host trailing slash is trimmed`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 204)])
        let client: JobRequestClient = .init(transport: transport)
        _ = try await client.requestJob(host: "https://h.invalid/", token: "t")
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.url.absoluteString == "https://h.invalid/api/v4/jobs/request")
    }
    /// 無 scheme 的 host 應被擋下。
    @Test
    func `host without scheme throws invalid url`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 204)])
        let client: JobRequestClient = .init(transport: transport)
        await #expect(throws: GitLabAPIError.invalidURL("h.invalid")) {
            _ = try await client.requestJob(host: "h.invalid", token: "t")
        }
    }
}

/// 回寫線（`PATCH …/trace` 與 `PUT /jobs/:id`）的協議行為。
private final class JobTraceAndStatusTests {

    /// trace 多段回寫：`Content-Range` 必須單調遞增且位移連續。
    @Test
    func `appendTrace accumulates content range across chunks`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 202)])
        let client: JobRequestClient = .init(transport: transport)
        var offset: Int = 0
        for chunk in ["hello", " world", "!"] {
            let data: Data = .init(chunk.utf8)
            _ = try await client.appendTrace(
                host: "https://h.invalid",
                jobID: 7,
                jobToken: "job-token",
                chunk: data,
                startOffset: offset
            )
            offset += data.count
        }
        let ranges: [String] = transport.requests.withLock { requests in
            requests.compactMap { $0.headers["Content-Range"] }
        }
        #expect(ranges == ["0-4", "5-10", "11-11"])
        let first: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(first.method == "PATCH")
        #expect(first.url.absoluteString == "https://h.invalid/api/v4/jobs/7/trace")
        #expect(first.headers["JOB-TOKEN"] == "job-token")
    }
    /// 取消偵測：站台只在 trace 回應標頭裡通知，這是唯一管道。
    @Test
    func `appendTrace surfaces cancellation from response header`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 202, headers: ["Job-Status": "canceled", "Range": "0-4"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let ack: TraceAck = try await client.appendTrace(
            host: "https://h.invalid",
            jobID: 7,
            jobToken: "job-token",
            chunk: .init("hello".utf8),
            startOffset: 0
        )
        #expect(ack.isCanceled)
        #expect(ack.nextOffset == 4)
    }
    /// 標頭查找不分大小寫——各層轉手後大小寫不保證。
    @Test
    func `appendTrace reads status header case insensitively`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 202, headers: ["job-status": "canceled"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let ack: TraceAck = try await client.appendTrace(
            host: "https://h.invalid",
            jobID: 1,
            jobToken: "t",
            chunk: .init("x".utf8),
            startOffset: 0
        )
        #expect(ack.isCanceled)
    }
    /// 空 chunk 不該發出請求（避免對站台送無意義的空 PATCH）。
    @Test
    func `appendTrace skips empty chunk`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 202)])
        let client: JobRequestClient = .init(transport: transport)
        let ack: TraceAck = try await client.appendTrace(
            host: "https://h.invalid",
            jobID: 1,
            jobToken: "t",
            chunk: .init(),
            startOffset: 0
        )
        #expect(ack.jobStatus == nil)
        #expect(transport.requests.withLock { $0.isEmpty })
    }
    /// 終態回報：狀態、失敗原因與結束碼進本體，走 job token。
    @Test
    func `updateJob sends terminal state with failure reason`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 200)])
        let client: JobRequestClient = .init(transport: transport)
        _ = try await client.updateJob(
            host: "https://h.invalid",
            jobID: 7,
            jobToken: "job-token",
            state: .failed,
            failureReason: .runnerSystemFailure,
            exitCode: 2
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.method == "PUT")
        #expect(request.url.absoluteString == "https://h.invalid/api/v4/jobs/7")
        let payload: [String: Any] = try jsonBody(of: request)
        #expect(payload["token"] as? String == "job-token")
        #expect(payload["state"] as? String == "failed")
        #expect(payload["failure_reason"] as? String == "runner_system_failure")
        #expect(payload["exit_code"] as? Int == 2)
    }
    /// 成功終態不帶 failure_reason（nil 欄位整鍵省略）。
    @Test
    func `updateJob omits failure reason on success`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 200)])
        let client: JobRequestClient = .init(transport: transport)
        _ = try await client.updateJob(
            host: "https://h.invalid",
            jobID: 7,
            jobToken: "job-token",
            state: .success
        )
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        let payload: [String: Any] = try jsonBody(of: request)
        #expect(payload["state"] as? String == "success")
        #expect(payload["failure_reason"] == nil)
        #expect(payload["exit_code"] == nil)
    }
    /// trace／狀態回報用短逾時、不套 long-poll 那個長值。
    @Test
    func `trace and update use short timeout`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 200)])
        let client: JobRequestClient = .init(transport: transport)
        _ = try await client.updateJob(host: "https://h.invalid", jobID: 1, jobToken: "t", state: .running)
        let request: HTTPRequest = try #require(transport.requests.withLock { $0.first })
        #expect(request.timeout == JobRequestClient.standardTimeout)
        #expect(try #require(request.timeout) < JobRequestClient.jobRequestTimeout)
    }
    /// 416：位移對不上時，站台用 `Range` 告訴我們該從哪裡續傳——這是唯一的重同步
    /// 依據，不能當成錯誤丟掉。
    @Test
    func `appendTrace surfaces resync offset on 416`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 416, headers: ["Range": "0-1024"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let ack: TraceAck = try await client.appendTrace(
            host: "https://h.invalid",
            jobID: 7,
            jobToken: "t",
            chunk: .init("misaligned".utf8),
            startOffset: 999
        )
        #expect(ack.needsResync)
        // 站台的 Range 端點＝已寫入總 byte 數＝下一段起始位移（開區間），
        // 與我們送出的閉區間端點語義相反、換算須收在協議層。
        #expect(ack.nextOffset == 1024)
    }
    /// 403＝站台剛把此 job 判死（trace 超限）或 token 失效，**且不帶任何標頭**
    /// （站台的 `error!` 先於所有 header 呼叫）——只能靠狀態碼辨識為中止。
    ///
    /// 這個 fixture 刻意不掛 `Job-Status`：掛了就會遮住「靠標頭判斷會失效」這件事。
    @Test
    func `appendTrace reports abort on bare 403`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 403)])
        let client: JobRequestClient = .init(transport: transport)
        let ack: TraceAck = try await client.appendTrace(
            host: "https://h.invalid",
            jobID: 7,
            jobToken: "t",
            chunk: .init("x".utf8),
            startOffset: 0
        )
        #expect(ack.isAborted)
        // 無標頭時 isCanceled 為 false——正因如此才不能用它當停止判準。
        #expect(ack.isCanceled == false)
    }
    /// 正常成功的 ack 不得被誤判為中止（與上一個 case 對照）。
    @Test
    func `appendTrace does not report abort on success`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 202)])
        let client: JobRequestClient = .init(transport: transport)
        let ack: TraceAck = try await client.appendTrace(
            host: "https://h.invalid", jobID: 1, jobToken: "t",
            chunk: .init("x".utf8), startOffset: 0
        )
        #expect(ack.isAborted == false)
        #expect(transport.requests.withLock { $0.count } == 1)
    }
    /// `Job-Status: failed` 也算中止（對齊 runner 的 IsFailed）。
    @Test
    func `appendTrace treats failed status as abort`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 202, headers: ["Job-Status": "failed"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let ack: TraceAck = try await client.appendTrace(
            host: "https://h.invalid", jobID: 1, jobToken: "t",
            chunk: .init("x".utf8), startOffset: 0
        )
        #expect(ack.isAborted)
    }
    /// 站台建議的回寫間隔要帶出來。
    @Test
    func `appendTrace surfaces update interval`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 202, headers: ["X-GitLab-Trace-Update-Interval": "30"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let ack: TraceAck = try await client.appendTrace(
            host: "https://h.invalid", jobID: 1, jobToken: "t",
            chunk: .init("x".utf8), startOffset: 0
        )
        #expect(ack.updateInterval == 30)
    }
    /// **202 不是成功**：狀態尚未寫入站台、必須重送。當成成功會讓 job 一直掛在
    /// running 到 accept timeout，CI 顯示假完成。
    @Test
    func `updateJob reports 202 as not completed`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 202, headers: ["X-GitLab-Trace-Update-Interval": "5"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let ack: JobUpdateAck = try await client.updateJob(
            host: "https://h.invalid", jobID: 7, jobToken: "t", state: .success
        )
        #expect(ack.isCompleted == false)
        #expect(ack.updateInterval == 5)
    }
    /// 200 才代表狀態真的寫入。
    @Test
    func `updateJob reports 200 as completed`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 200)])
        let client: JobRequestClient = .init(transport: transport)
        let ack: JobUpdateAck = try await client.updateJob(
            host: "https://h.invalid", jobID: 7, jobToken: "t", state: .success
        )
        #expect(ack.isCompleted)
    }
    /// keepalive 收到 403 ＋ `Job-Status: canceled`＝使用者按了取消。
    ///
    /// 對「沒有新 log 可送的安靜 job」這是取消唯一會浮現的地方
    /// （`authenticate_job!` → `job_forbidden!` 先帶標頭再回 403）。若把它 throw 成
    /// 不明錯誤，呼叫端會當暫時性失敗重試、VM 與 script 一路跑到 timeout。
    @Test
    func `updateJob reports abort on 403 with job status`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 403, headers: ["Job-Status": "canceled"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let ack: JobUpdateAck = try await client.updateJob(
            host: "https://h.invalid", jobID: 7, jobToken: "t", state: .running
        )
        #expect(ack.isAborted)
        #expect(ack.isCanceled)
        #expect(ack.isCompleted == false)
    }

    /// token 失效類的 403 不帶標頭，仍必須辨識為中止（狀態碼才是主判準）。
    @Test
    func `updateJob reports abort on bare 403`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 403)])
        let client: JobRequestClient = .init(transport: transport)
        let ack: JobUpdateAck = try await client.updateJob(
            host: "https://h.invalid", jobID: 7, jobToken: "t", state: .running
        )
        #expect(ack.isAborted)
        #expect(ack.isCanceled == false)
    }

    /// 正常回報不得被誤判為中止。
    @Test
    func `updateJob does not report abort on success`() async throws {
        let transport: ScriptedTransport = .init([.init(statusCode: 200)])
        let client: JobRequestClient = .init(transport: transport)
        let ack: JobUpdateAck = try await client.updateJob(
            host: "https://h.invalid", jobID: 7, jobToken: "t", state: .success
        )
        #expect(ack.isAborted == false)
        #expect(transport.requests.withLock { $0.count } == 1)
    }

    /// 成功路徑（200／202）在 16.2 不帶 `Job-Status`，但若站台帶了就讀得到。
    /// 取消是走上面那條 403 路徑浮現，不是走成功路徑。
    @Test
    func `updateJob exposes job status header when present`() async throws {
        let transport: ScriptedTransport = .init([
            .init(statusCode: 200, headers: ["Job-Status": "canceled"])
        ])
        let client: JobRequestClient = .init(transport: transport)
        let ack: JobUpdateAck = try await client.updateJob(
            host: "https://h.invalid", jobID: 7, jobToken: "t", state: .running
        )
        #expect(ack.isCanceled)
    }
    /// `Range` 格式非預期時不得亂猜位移——寧可回 nil 讓上層停手。
    @Test
    func `appendTrace yields no offset for malformed range`() async throws {
        for malformed in ["0-", "1024", "", "0-abc"] {
            let transport: ScriptedTransport = .init([
                .init(statusCode: 416, headers: ["Range": malformed])
            ])
            let client: JobRequestClient = .init(transport: transport)
            let ack: TraceAck = try await client.appendTrace(
                host: "https://h.invalid", jobID: 1, jobToken: "t",
                chunk: .init("x".utf8), startOffset: 0
            )
            #expect(ack.needsResync)
            #expect(ack.nextOffset == nil, "Range=\(malformed) 不該解出位移")
        }
    }
}
