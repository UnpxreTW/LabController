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

/// 從請求本體解出 JSON 物件；解不出即測試失敗。
private func updateBody(of request: HTTPRequest) throws -> [String: Any] {
    let data: Data = try #require(request.body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// 本檔測試共用的回寫座標；全為合成值。
private let target: JobReportTarget = .init(
    host: "https://gitlab.example.invalid", identifier: 7, token: "synthetic-job-token"
)

private final class JobResultReporterTests {

    /// 一般路徑：log 一段送完、終態寫進站台，兩支端點的位址與標頭都對。
    @Test
    func `sends the trace then writes the terminal state`() async throws {
        let transport: QueuedTransport = .init([
            .init(statusCode: 202, headers: ["Range": "0-5"]),
            .init(statusCode: 200),
        ])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(delivery.acceptance == .written)
        #expect(delivery.traceIsComplete)
        #expect(delivery.updateAttempts == 1)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].url.absoluteString == "https://gitlab.example.invalid/api/v4/jobs/7/trace")
        // 送出端是閉區間：五個 byte 從 0 起算，結尾是 4。
        #expect(requests[0].headers["Content-Range"] == "0-4")
        #expect(requests[0].headers["JOB-TOKEN"] == "synthetic-job-token")
        #expect(requests[0].body == .init("hello".utf8))
        #expect(requests[1].method == "PUT")
        #expect(requests[1].url.absoluteString == "https://gitlab.example.invalid/api/v4/jobs/7")
    }

    /// 長 log 依設定的段落大小切開，位移逐段接續。
    @Test
    func `splits a long trace into chunks`() async throws {
        let transport: QueuedTransport = .init([
            .init(statusCode: 202), .init(statusCode: 202), .init(statusCode: 202), .init(statusCode: 200),
        ])
        let reporter: JobResultReporter = .init(
            client: .init(transport: transport),
            configuration: .init(traceChunkBytes: 4),
            wait: { _ in }
        )
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "0123456789")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(delivery.traceIsComplete)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        #expect(requests.count == 4)
        #expect(requests.prefix(3).map { $0.headers["Content-Range"] } == ["0-3", "4-7", "8-9"])
        #expect(requests[2].body == .init("89".utf8))
    }

    /// 站台說它收到哪裡，就從那裡續傳——不照本側送出的量自行推進。
    @Test
    func `follows the offset reported by the site`() async throws {
        let transport: QueuedTransport = .init([
            .init(statusCode: 202, headers: ["Range": "0-6"]),
            .init(statusCode: 202),
            .init(statusCode: 200),
        ])
        let reporter: JobResultReporter = .init(
            client: .init(transport: transport),
            configuration: .init(traceChunkBytes: 4),
            wait: { _ in }
        )
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "0123456789")
        _ = try await reporter.report(report, to: target)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        #expect(requests.prefix(2).map { $0.headers["Content-Range"] } == ["0-3", "6-9"])
    }

    /// 位移對不上時（416）照站台帶回的位置重送。
    @Test
    func `resends from the offset carried by a 416`() async throws {
        let transport: QueuedTransport = .init([
            .init(statusCode: 416, headers: ["Range": "0-2"]),
            .init(statusCode: 202),
            .init(statusCode: 200),
        ])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(delivery.traceIsComplete)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        #expect(requests.prefix(2).map { $0.headers["Content-Range"] } == ["0-4", "2-4"])
        #expect(requests[1].body == .init("llo".utf8))
    }

    /// 416 卻沒帶位置＝無從續傳：放棄 log，但終態照送。
    @Test
    func `gives up the trace but still writes the state when 416 carries no offset`() async throws {
        let transport: QueuedTransport = .init([.init(statusCode: 416), .init(statusCode: 200)])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(delivery.acceptance == .written)
        #expect(!delivery.traceIsComplete)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[1].method == "PUT")
    }

    /// 反覆對不上就停手，不把同一段來回灌；終態仍寫得進去。
    @Test
    func `stops resyncing after the attempt limit`() async throws {
        let transport: QueuedTransport = .init([
            .init(statusCode: 416, headers: ["Range": "0-0"]),
            .init(statusCode: 416, headers: ["Range": "0-0"]),
            .init(statusCode: 200),
        ])
        let reporter: JobResultReporter = .init(
            client: .init(transport: transport),
            configuration: .init(maximumResyncAttempts: 1),
            wait: { _ in }
        )
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(!delivery.traceIsComplete)
        #expect(delivery.acceptance == .written)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        #expect(requests.count == 3)
        #expect(requests[2].method == "PUT")
    }

    /// 站台在送 log 的途中說這件 job 已經不在跑了：整個停手，連終態都不送。
    @Test
    func `stops entirely when the site forbids the trace`() async throws {
        let transport: QueuedTransport = .init([.init(statusCode: 403, headers: ["Job-Status": "canceled"])])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(delivery.acceptance == .aborted)
        #expect(!delivery.traceIsComplete)
        #expect(delivery.updateAttempts == 0)
        #expect(transport.requests.withLock { $0.count } == 1)
    }

    /// 沒有 log 可送時不發那支請求，直接寫終態。
    @Test
    func `sends no trace request when the trace is empty`() async throws {
        let transport: QueuedTransport = .init([.init(statusCode: 200)])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let delivery: JobReportDelivery = try await reporter.report(.init(outcome: .completed, exitCode: 0),
                                                                   to: target)
        #expect(delivery.acceptance == .written)
        #expect(delivery.traceIsComplete)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests[0].method == "PUT")
    }

    /// 202 不是寫入：依站台建議的間隔等一會再送一次，直到它真的寫進去。
    @Test
    func `resends the terminal state until the site writes it`() async throws {
        let transport: QueuedTransport = .init([
            .init(statusCode: 202),
            .init(statusCode: 202, headers: ["X-GitLab-Trace-Update-Interval": "7"]),
            .init(statusCode: 200),
        ])
        let waits: Mutex<[TimeInterval]> = .init([])
        let reporter: JobResultReporter = .init(
            client: .init(transport: transport),
            wait: { seconds in waits.withLock { $0.append(seconds) } }
        )
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(delivery.acceptance == .written)
        #expect(delivery.updateAttempts == 2)
        #expect(waits.withLock { $0 } == [7])
    }

    /// 站台沒建議間隔時用本機設定的那個值。
    @Test
    func `waits the configured interval when the site suggests none`() async throws {
        let transport: QueuedTransport = .init([
            .init(statusCode: 202), .init(statusCode: 202), .init(statusCode: 200),
        ])
        let waits: Mutex<[TimeInterval]> = .init([])
        let reporter: JobResultReporter = .init(
            client: .init(transport: transport),
            configuration: .init(updateRetryInterval: 2),
            wait: { seconds in waits.withLock { $0.append(seconds) } }
        )
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        _ = try await reporter.report(report, to: target)
        #expect(waits.withLock { $0 } == [2])
    }

    /// 站台一直只收下不寫入：送到次數上限就如實回「沒被確認」，不無限敲。
    @Test
    func `stops resending after the update attempt limit`() async throws {
        let transport: QueuedTransport = .init([.init(statusCode: 202), .init(statusCode: 202)])
        let waits: Mutex<[TimeInterval]> = .init([])
        let reporter: JobResultReporter = .init(
            client: .init(transport: transport),
            configuration: .init(maximumUpdateAttempts: 3),
            wait: { seconds in waits.withLock { $0.append(seconds) } }
        )
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(delivery.acceptance == .notAcknowledged)
        #expect(delivery.updateAttempts == 3)
        // 最後一次之後不再等待：等完也不會再送。
        #expect(waits.withLock { $0.count } == 2)
    }

    /// 終態被擋下（403）＝這件 job 已經不在跑了，不重送。
    @Test
    func `stops when the site forbids the terminal state`() async throws {
        let transport: QueuedTransport = .init([
            .init(statusCode: 202, headers: ["Range": "0-5"]),
            .init(statusCode: 403, headers: ["Job-Status": "canceled"]),
        ])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "hello")
        let delivery: JobReportDelivery = try await reporter.report(report, to: target)
        #expect(delivery.acceptance == .aborted)
        #expect(delivery.updateAttempts == 1)
        #expect(delivery.traceIsComplete)
    }

    /// 紅了的 job：狀態、失敗分類與結束碼一起送出去。
    @Test
    func `reports a failed job with its reason and exit code`() async throws {
        let transport: QueuedTransport = .init([.init(statusCode: 202), .init(statusCode: 200)])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let report: JobRunReport = .init(
            outcome: .jobFailed, failureReason: .scriptFailure, exitCode: 2, trace: "boom"
        )
        _ = try await reporter.report(report, to: target)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        let body: [String: Any] = try updateBody(of: requests[1])
        #expect(body["state"] as? String == "failed")
        #expect(body["failure_reason"] as? String == "script_failure")
        #expect(body["exit_code"] as? Int == 2)
        #expect(body["token"] as? String == "synthetic-job-token")
    }

    /// 撞到時間上限的 job 也是紅的，但分類是逾時——站台據此決定要不要重試。
    @Test
    func `reports a timed out job as a timeout failure`() async throws {
        let transport: QueuedTransport = .init([.init(statusCode: 200)])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let report: JobRunReport = .init(outcome: .timeout, failureReason: .jobExecutionTimeout)
        _ = try await reporter.report(report, to: target)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        let body: [String: Any] = try updateBody(of: requests[0])
        #expect(body["state"] as? String == "failed")
        #expect(body["failure_reason"] as? String == "job_execution_timeout")
        // 沒有任何結束碼決定得了結果時整鍵省略、不送 0 假裝有。
        #expect(body["exit_code"] == nil)
    }

    /// 跑完的 job 不帶失敗分類——那個欄位在成功路徑上只會變成站台紀錄裡的雜訊。
    @Test
    func `omits the failure reason for a completed job`() async throws {
        let transport: QueuedTransport = .init([.init(statusCode: 200)])
        let reporter: JobResultReporter = .init(client: .init(transport: transport), wait: { _ in })
        let report: JobRunReport = .init(outcome: .completed, failureReason: .scriptFailure, exitCode: 0)
        _ = try await reporter.report(report, to: target)
        let requests: [HTTPRequest] = transport.requests.withLock { $0 }
        let body: [String: Any] = try updateBody(of: requests[0])
        #expect(body["state"] as? String == "success")
        #expect(body["failure_reason"] == nil)
        #expect(body["exit_code"] as? Int == 0)
    }
}
