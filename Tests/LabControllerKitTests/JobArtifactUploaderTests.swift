//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LabControllerKit
import Foundation
import Synchronization
import Testing

// MARK: - UploadTransport

/// 依序播放的假傳輸，序列裡可以排連不上的那一次。
///
/// 全部為合成資料（假 id／token／站台位址）。序列耗盡後重複最後一步。
private final class UploadTransport: HTTPTransport, Sendable {

	/// 以步驟序列建立。
	///
	/// - Parameter steps: 依序播放的步驟。
	fileprivate init(_ steps: [Step]) {
		self.steps = .init(steps)
	}

	/// 一次呼叫要發生什麼。
	fileprivate enum Step {

		/// 回這個狀態碼。
		case respond(Int)

		/// 回 307、帶這個 `Location`。
		case redirect(String)

		/// 這一次連不上。
		case fail
	}

	/// 收到的請求，依序累積。
	fileprivate let requests: Mutex<[HTTPRequest]> = .init([])

	/// 記錄請求，播放序列中的下一步。
	///
	/// - Parameter request: 送出的請求。
	/// - Returns: 這一步排定的回應。
	/// - Throws: 這一步排的是連不上時拋 `URLError`。
	fileprivate func send(_ request: HTTPRequest) async throws -> HTTPResponse {
		requests.withLock { $0.append(request) }
		let step: Step = steps.withLock { queue in
			queue.count > 1 ? queue.removeFirst() : (queue.first ?? .fail)
		}
		switch step {
		case let .respond(statusCode): return .init(statusCode: statusCode)
		case let .redirect(location): return .init(statusCode: 307, headers: ["Location": location])
		case .fail: throw URLError(.networkConnectionLost)
		}
	}

	/// 待播放的步驟序列。
	private let steps: Mutex<[Step]>
}

// MARK: - Fixtures

/// 一份合成產物。
///
/// - Parameter name: 產物名稱。
/// - Returns: 帶著幾個位元組內容的產物。
private func artifact(named name: String) -> CollectedArtifact {
	.init(declaration: .init(name: name, paths: ["out"]), archive: .init("PK".utf8))
}

// MARK: - UploadRun

/// 一次上傳跑完之後要斷言的三樣東西。
private struct UploadRun {

	/// 上傳結果。
	fileprivate let summary: JobArtifactUploadSummary

	/// 送出的請求，依序。
	fileprivate let requests: [HTTPRequest]

	/// 每一次等待的秒數，依序。
	fileprivate let waits: [TimeInterval]
}

/// 把送出、等待、結果收在一起，方便逐項斷言。
///
/// - Parameters:
///   - artifacts: 要送的產物。
///   - steps: 假傳輸的步驟序列。
///   - masker: 遮蔽規則。
/// - Returns: 上傳結果、送出的請求與每一次等待的秒數。
private func run(
	_ artifacts: [CollectedArtifact],
	steps: [UploadTransport.Step],
	masker: TraceMasker = .init(maskedValues: [])
) async -> UploadRun {
	let transport: UploadTransport = .init(steps)
	let waits: Mutex<[TimeInterval]> = .init([])
	let uploader: JobArtifactUploader = .init(
		client: .init(transport: transport),
		wait: { seconds in
			waits.withLock { $0.append(seconds) }
		}
	)
	let summary: JobArtifactUploadSummary = await uploader.upload(artifacts, to: syntheticReportTarget, masker: masker)
	return .init(summary: summary, requests: transport.requests.withLock { $0 }, waits: waits.withLock { $0 })
}

// MARK: - JobArtifactUploaderTests

/// 產物的上傳：重送幾次、什麼情況不重送、送失敗之後還送不送後面的。
private final class JobArtifactUploaderTests {

	/// 站台照常收下時每份只送一次、不等待，並用這件 job 的專屬 token。
	@Test
	private func `uploads each artifact once when the server accepts`() async throws {
		let outcome: UploadRun = await run([artifact(named: "first"), artifact(named: "second")], steps: [.respond(201)])
		#expect(!outcome.summary.hasFailed)
		#expect(outcome.requests.count == 2)
		#expect(outcome.waits.isEmpty)
		let request: HTTPRequest = try #require(outcome.requests.first)
		#expect(request.url.path.hasSuffix("/jobs/7/artifacts"))
		#expect(request.headers["JOB-TOKEN"] == "synthetic-job-token")
		#expect(outcome.summary.traceLines.count(where: { $0.hasSuffix("已上傳。") }) == 2)
	}

	/// 其餘狀態碼最多送 3 次；兩次之間 1、2 秒。
	@Test
	private func `retries a server error up to three attempts`() async {
		let outcome: UploadRun = await run([artifact(named: "out")], steps: [.respond(500)])
		#expect(outcome.summary.hasFailed)
		#expect(outcome.requests.count == 3)
		#expect(outcome.waits == [1, 2])
	}

	/// 站台回 503 時放寬到 6 次；等待從 1 秒倍增、最多 5 秒。
	@Test
	private func `retries service unavailable up to six attempts`() async {
		let outcome: UploadRun = await run([artifact(named: "out")], steps: [.respond(503)])
		#expect(outcome.summary.hasFailed)
		#expect(outcome.requests.count == 6)
		#expect(outcome.waits == [1, 2, 4, 5, 5])
	}

	/// 連不上與 503 都是暫時的：之後送上去就算成功。
	@Test
	private func `succeeds after transient failures`() async {
		let outcome: UploadRun = await run([artifact(named: "out")], steps: [.fail, .respond(503), .respond(201)])
		#expect(!outcome.summary.hasFailed)
		#expect(outcome.requests.count == 3)
		#expect(outcome.waits == [1, 2])
	}

	/// 403 不重送，後面的產物也不再送。
	@Test
	private func `stops at forbidden without retrying or sending the rest`() async {
		let outcome: UploadRun = await run([artifact(named: "first"), artifact(named: "second")], steps: [.respond(403)])
		#expect(outcome.summary.hasFailed)
		#expect(outcome.requests.count == 1)
		#expect(outcome.waits.isEmpty)
		#expect(!outcome.summary.traceLines.contains { $0.contains("second") })
	}

	/// 413 不重送：檔案大小不會因為重送而改變。
	@Test
	private func `does not retry an oversized artifact`() async {
		let outcome: UploadRun = await run([artifact(named: "out")], steps: [.respond(413)])
		#expect(outcome.summary.hasFailed)
		#expect(outcome.requests.count == 1)
	}

	/// 307 不跟：不改送到別的主機，`Location` 也不進 trace。
	@Test
	private func `does not follow a redirect`() async {
		let outcome: UploadRun = await run(
			[artifact(named: "out")],
			steps: [.redirect("https://elsewhere.example.invalid/x")]
		)
		#expect(outcome.summary.hasFailed)
		#expect(outcome.requests.count == 1)
		#expect(outcome.requests.allSatisfy { $0.url.host == "gitlab.example.invalid" })
		#expect(!outcome.summary.traceLines.contains { $0.contains("elsewhere") })
	}

	/// 檔名由 payload 而來，trace 行要過遮蔽。
	@Test
	private func `masks payload derived names in trace lines`() async {
		let masker: TraceMasker = .init(maskedValues: ["hidden-release-key"])
		let outcome: UploadRun = await run(
			[artifact(named: "build-hidden-release-key")],
			steps: [.respond(500)],
			masker: masker
		)
		#expect(!outcome.summary.traceLines.isEmpty)
		#expect(!outcome.summary.traceLines.contains { $0.contains("hidden-release-key") })
	}

	/// 沒有產物時不送任何請求、結果是空的。
	@Test
	private func `sends nothing when there is nothing to upload`() async {
		let outcome: UploadRun = await run([], steps: [.respond(201)])
		#expect(outcome.summary == .init())
		#expect(outcome.requests.isEmpty)
	}
}

// MARK: - JobArtifactUploadSummaryTests

/// 上傳結果併進 job 結果：哪一種情況改寫終態、哪一種保留原本的死因。
private final class JobArtifactUploadSummaryTests {

	/// job 成功、上傳失敗＝job 失敗（`script_failure`、無結束碼），trace 接在後面。
	@Test
	private func `failed upload turns a completed job into a job failure`() {
		let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "step\n")
		let summary: JobArtifactUploadSummary = .init(traceLines: ["upload failed"], hasFailed: true)
		let merged: JobRunReport = summary.applied(to: report)
		#expect(merged.outcome == .jobFailed)
		#expect(merged.failureReason == .scriptFailure)
		#expect(merged.exitCode == nil)
		#expect(merged.trace == "step\nupload failed\n")
	}

	/// job 本身已經失敗時保留原本的死因與結束碼。
	@Test
	private func `failed upload keeps the original job failure`() {
		let report: JobRunReport = .init(outcome: .jobFailed, failureReason: .scriptFailure, exitCode: 2, trace: "step")
		let summary: JobArtifactUploadSummary = .init(traceLines: ["upload failed"], hasFailed: true)
		let merged: JobRunReport = summary.applied(to: report)
		#expect(merged.outcome == .jobFailed)
		#expect(merged.exitCode == 2)
		#expect(merged.trace == "step\nupload failed\n")
	}

	/// 上傳成功時終態不變，只接上 trace。
	@Test
	private func `successful upload keeps the outcome`() {
		let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "step\n")
		let merged: JobRunReport = JobArtifactUploadSummary(traceLines: ["uploaded"]).applied(to: report)
		#expect(merged.outcome == .completed)
		#expect(merged.exitCode == 0)
		#expect(merged.trace == "step\nuploaded\n")
	}

	/// 沒有要接的行時 trace 原樣保留，不多出換行。
	@Test
	private func `empty summary leaves the trace untouched`() {
		let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "step")
		#expect(JobArtifactUploadSummary().applied(to: report) == report)
	}
}

// MARK: - ArtifactUploadSessionTests

/// 上傳專用 session 的整體時長：照參數、與共用的 600 秒分開。
private final class ArtifactUploadSessionTests {

	/// 整體上限照給的值，而不是共用 session 的 600 秒。
	@Test
	private func `resource timeout follows the given value`() {
		let configuration: URLSessionConfiguration = URLSessionTransport.artifactUploadConfiguration(resourceTimeout: 9000)
		#expect(configuration.timeoutIntervalForResource == 9000)
		#expect(configuration.urlCache == nil)
		#expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
	}

	/// 不大於 0 的值取預設值，不會變成「立刻逾時」。
	@Test
	private func `non positive resource timeout falls back to the default`() {
		for value in [0, -1] as [TimeInterval] {
			let configuration: URLSessionConfiguration = URLSessionTransport.artifactUploadConfiguration(resourceTimeout: value)
			#expect(configuration.timeoutIntervalForResource == URLSessionTransport.defaultArtifactUploadResourceTimeout)
		}
	}
}
