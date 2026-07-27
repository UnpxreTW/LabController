//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// runner 協議中「領 job → 回寫 log → 回報成敗」三支端點的 client。
///
/// 與 `RunnerRegistrationClient` 平行、不共用型別：註冊用 registration token 換
/// runner 認證 token，本 client 則用 runner 認證 token 領 job、再用 job 專屬 token
/// 回寫。兩者 token 域不同，混用即為權限錯置。
///
/// 本片只到協議層——領到 job 之後怎麼跑（VM、clone、script）由後續切片承接。
///
/// 形狀依據：GitLab 16.2 的 `lib/api/ci/runner.rb`、`workhorse/internal/builds/register.go`、
/// `app/services/ci/register_job_service.rb`，以及 gitlab-runner v16.2 的
/// `network/gitlab.go`（此組屬 runner 內部 API、官方文件不完整、以原始碼為準）。
public struct JobRequestClient: Sendable {

    /// long-poll 的請求逾時；必須大於站台端 hold 的時間（實測約 50 秒），
    /// 否則 client 會自己先斷、白費被 hold 的連線又反覆敲站台。
    public static let jobRequestTimeout: TimeInterval = 75

    /// 一般請求（trace／狀態回報）的逾時；這類應快速失敗。
    public static let standardTimeout: TimeInterval = 30

    /// 傳輸層；正式路徑用 `URLSessionTransport`、測試注入假傳輸。
    private let transport: any HTTPTransport

    /// 以指定傳輸建立；未指定時採 URLSession 正式路徑。
    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// `POST /api/v4/jobs/request`：long-poll 領一個 job。
    ///
    /// 201＝指派了 job；204＝此刻無 job（正常路徑、非錯誤）。
    ///
    /// `lastUpdate` 必須放進 **JSON body**（不是請求標頭）——Workhorse 的
    /// `RegisterHandler` 從 body 取 `last_update`，取不到就直接把請求 proxy 給
    /// Rails、**完全不 hold**，long-poll 等於沒開。回傳的游標已與傳入值合併
    /// （站台只在 204 分支發新游標），可直接沿用。
    ///
    /// `info` 的能力宣告會影響站台指派：宣告不足會讓需要該能力的 job 被
    /// `drop!`（見 `RunnerFeatures`），務必如實填寫。
    public func requestJob(
        host: String,
        token: String,
        lastUpdate: String? = nil,
        info: RunnerInfo = .init()
    ) async throws -> JobRequestResult {
        let payload: JobRequestPayload = .init(token: token, lastUpdate: lastUpdate, info: info)
        let response: HTTPResponse = try await send(
            method: "POST",
            host: host,
            path: "jobs/request",
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(payload),
            timeout: Self.jobRequestTimeout
        )
        // 站台只在 204 分支發游標；沒收到就沿用舊值，別覆寫成 nil。
        let cursor: String? = response.headerValue("X-GitLab-Last-Update") ?? lastUpdate
        switch response.statusCode {
        case 201:
            guard let job: JobResponse = try? JSONDecoder().decode(JobResponse.self, from: response.body) else {
                throw GitLabAPIError.undecodableBody
            }
            return .init(outcome: .assigned(job), lastUpdate: cursor)
        case 204:
            return .init(outcome: .noJob, lastUpdate: cursor)
        default:
            throw GitLabAPIError.unexpectedStatus(response.statusCode)
        }
    }

    /// `PATCH /api/v4/jobs/:id/trace`：把一段增量 log 附加到 job 的輸出。
    ///
    /// `startOffset` 是這段內容在整份 log 中的起始 byte 位移，`Content-Range` 以
    /// **閉區間**表達（`start-(start+count-1)`、與 runner 實作一致）。
    ///
    /// 416 與 403 **不當成錯誤拋出**：416 的 `Range` 標頭帶著站台實際收到的位置，
    /// 是位移對不上時唯一的重同步依據。403 代表 job 已非 running（取消／已結束）
    /// 或 token 失效／trace 超限；**取消造成的 403 帶 `Job-Status`、其餘不帶**，
    /// 故以 `TraceAck.isAborted`（狀態碼為主判準）呈現。呼叫端必須據此停止回寫，
    /// 不可當成普通 ack 繼續灌 log（會一路灌進黑洞、到回報終態才發現）。
    public func appendTrace(
        host: String,
        jobID: Int,
        jobToken: String,
        chunk: Data,
        startOffset: Int
    ) async throws -> TraceAck {
        guard !chunk.isEmpty else {
            return .init()
        }
        let endOffset: Int = startOffset + chunk.count - 1
        let response: HTTPResponse = try await send(
            method: "PATCH",
            host: host,
            path: "jobs/\(jobID)/trace",
            headers: [
                "Content-Type": "text/plain",
                "Content-Range": "\(startOffset)-\(endOffset)",
                "JOB-TOKEN": jobToken,
            ],
            body: chunk,
            timeout: Self.standardTimeout
        )
        let status: String? = response.headerValue("Job-Status")
        let interval: TimeInterval? = response.headerValue("X-GitLab-Trace-Update-Interval")
            .flatMap(TimeInterval.init)
        let offset: Int? = Self.nextOffset(from: response.headerValue("Range"))
        switch response.statusCode {
        case 200 ... 202:
            return .init(
                jobStatus: status, nextOffset: offset,
                updateInterval: interval, statusCode: response.statusCode
            )
        case 416:
            return .init(
                jobStatus: status, nextOffset: offset, needsResync: true,
                updateInterval: interval, statusCode: response.statusCode
            )
        case 403:
            // job 已非 running（取消／已結束）、token 失效，或 trace 超限被 drop。
            // 只有「job 非 running」那條帶 Job-Status、其餘不帶 → 靠狀態碼判 isAborted。
            return .init(
                jobStatus: status, nextOffset: offset,
                updateInterval: interval, statusCode: response.statusCode
            )
        default:
            throw GitLabAPIError.unexpectedStatus(response.statusCode)
        }
    }

    /// `PUT /api/v4/jobs/:id`：回報 job 的狀態或終態。
    ///
    /// **200 才是「已寫入」**；202 代表站台收下但尚未完成（trace 未落地），必須依
    /// `updateInterval` 重送，否則 job 會一直掛在 running。回傳的
    /// `JobUpdateAck.isCompleted` 就是這個區別。
    ///
    /// 403 **不當成錯誤拋出**：它代表 job 已非 running（取消／已結束）或 token
    /// 失效。對「沒有新 log 可送的安靜 job」，這條 keepalive 403 是取消唯一會浮現
    /// 的地方（`authenticate_job!` → `job_forbidden!` 會先帶 `Job-Status`），
    /// 丟掉就等於看不見取消。以 `JobUpdateAck.isAborted` 呈現、與 trace 那支對稱。
    ///
    /// `failureReason` 只在 `state` 為 `.failed` 時有意義；它決定站台端要不要重試
    /// （程式錯不重試、環境錯可重試）。
    public func updateJob(
        host: String,
        jobID: Int,
        jobToken: String,
        state: JobState,
        failureReason: JobFailureReason? = nil,
        exitCode: Int? = nil
    ) async throws -> JobUpdateAck {
        let payload: JobUpdatePayload = .init(
            token: jobToken,
            state: state.rawValue,
            failureReason: failureReason?.rawValue,
            exitCode: exitCode
        )
        let response: HTTPResponse = try await send(
            method: "PUT",
            host: host,
            path: "jobs/\(jobID)",
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(payload),
            timeout: Self.standardTimeout
        )
        let status: String? = response.headerValue("Job-Status")
        let interval: TimeInterval? = response.headerValue("X-GitLab-Trace-Update-Interval")
            .flatMap(TimeInterval.init)
        switch response.statusCode {
        case 200:
            return .init(
                isCompleted: true, jobStatus: status,
                updateInterval: interval, statusCode: response.statusCode
            )
        case 202:
            return .init(
                isCompleted: false, jobStatus: status,
                updateInterval: interval, statusCode: response.statusCode
            )
        case 403:
            // job 已非 running（取消／已結束）或 token 失效。取消造成的 403 帶
            // Job-Status、token 造成的不帶——一律以 isAborted 呈現，不 throw 掉，
            // 否則呼叫端看到的與連線層錯誤無異、多半會當暫時性失敗重試，
            // 讓 VM 與 script 一路跑到 job timeout。
            return .init(
                isCompleted: false, jobStatus: status,
                updateInterval: interval, statusCode: response.statusCode
            )
        default:
            throw GitLabAPIError.unexpectedStatus(response.statusCode)
        }
    }

    /// 從站台回的 `Range: 0-<n>` 取出下一段的起始位移。
    ///
    /// 站台的 `n`＝已寫入的總 byte 數（開區間端點），直接就是下一段的起始位移；
    /// 與送出端的閉區間端點不同，換算在此收斂、不外流給呼叫端。
    static func nextOffset(from range: String?) -> Int? {
        guard let range, let dash: String.Index = range.lastIndex(of: "-") else {
            return nil
        }
        return Int(range[range.index(after: dash)...])
    }

    /// 組出 `{host}/api/v4/{path}` 並送出；host 結尾多餘的斜線會先修剪。
    private func send(
        method: String,
        host: String,
        path: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> HTTPResponse {
        let base: String = host.hasSuffix("/") ? .init(host.dropLast()) : host
        guard let url: URL = .init(string: "\(base)/api/v4/\(path)"), url.scheme != nil else {
            throw GitLabAPIError.invalidURL(host)
        }
        let request: HTTPRequest = .init(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: timeout
        )
        return try await transport.send(request)
    }
}

/// `POST /api/v4/jobs/request` 的請求本體。
///
/// `last_update` 必須在 body——Workhorse 由此判斷要不要 hold 住連線做 long-poll。
private struct JobRequestPayload: Encodable {

    /// runner 認證 token。
    let token: String

    /// 上一輪拿到的游標；nil 時整鍵省略。
    let lastUpdate: String?

    /// runner 自述與能力宣告。
    let info: RunnerInfo

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case token
        case lastUpdate = "last_update"
        case info
    }
}

/// `PUT /api/v4/jobs/:id` 的請求本體；nil 欄位整鍵省略。
private struct JobUpdatePayload: Encodable {

    /// job 專屬 token。
    let token: String

    /// 目標狀態。
    let state: String

    /// 失敗原因；非失敗時為 nil。
    let failureReason: String?

    /// script 的結束碼；未知時為 nil。
    let exitCode: Int?

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case token
        case state
        case failureReason = "failure_reason"
        case exitCode = "exit_code"
    }
}
