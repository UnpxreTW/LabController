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

// MARK: - RoutingTransport

/// 依網址分派回應的假傳輸：領件回一件帶產物宣告的 job、上傳回指定的狀態碼，其餘一律 200。
///
/// 全部為合成資料（假 id／token／站台位址）。
private final class RoutingTransport: HTTPTransport, Sendable {

	/// 以上傳要回的狀態碼建立。
	///
	/// - Parameter uploadStatus: 每一次上傳都回這個狀態碼。
	fileprivate init(uploadStatus: Int) {
		self.uploadStatus = uploadStatus
	}

	/// 收到的請求，依序累積。
	fileprivate let requests: Mutex<[HTTPRequest]> = .init([])

	/// 記錄請求，依網址回應。
	///
	/// - Parameter request: 送出的請求。
	/// - Returns: 對應這條網址的回應。
	fileprivate func send(_ request: HTTPRequest) async throws -> HTTPResponse {
		requests.withLock { $0.append(request) }
		if request.url.path.hasSuffix("/jobs/request") {
			return assignedJobWithArtifacts
		}
		if request.url.path.hasSuffix("/artifacts") {
			return .init(statusCode: uploadStatus)
		}
		return .init(statusCode: 200)
	}

	/// 上傳要回的狀態碼。
	private let uploadStatus: Int
}

// MARK: - Fixtures

/// 站台指派一件宣告了 `paths` 產物的 job；全為合成值。
private let assignedJobWithArtifacts: HTTPResponse = .init(
	statusCode: 201,
	body: .init(#"""
		{"id":7,"token":"synthetic-job-token",
		 "steps":[{"name":"script","script":["swift build"],"allow_failure":false}],
		 "artifacts":[{"name":"build","paths":["build"],"when":"on_success",
		               "artifact_type":"archive","artifact_format":"zip"}],
		 "git_info":{"repo_url":"https://example.invalid/g/a.git","ref":"main","sha":"deadbeef"}}
		"""#.utf8)
)

/// 執行環境裡打包出來的那份檔案。
private let archive: Data = .init("PK-synthetic".utf8)

/// 一個執行環境：打包腳本印出大小或 `none`，分塊讀取回那份檔案。
///
/// - Parameter packedOutput: 打包腳本的標準輸出。
/// - Returns: 照劇本回應的後端。
private func backend(packing packedOutput: String) -> InMemoryExecutionBackend {
	.init(script: .init(handler: { command in
		if command.last == "/tmp/labcontroller/artifacts/pack-0.sh" {
			return .init(command: command, exitCode: 0, standardOutput: .init(packedOutput.utf8))
		}
		guard command.count >= 3, command[command.count - 3] == "/tmp/labcontroller/artifacts/read.sh" else {
			return nil
		}
		let output: String = "labcontroller-chunk\n" + archive.base64EncodedString() + "\n"
		return .init(command: command, exitCode: 0, standardOutput: .init(output.utf8))
	}))
}

/// 跑一輪迴圈，回傳這一輪送出去的全部請求。
///
/// - Parameters:
///   - uploadStatus: 上傳要回的狀態碼。
///   - packedOutput: 打包腳本的標準輸出。
/// - Returns: 這一輪的處置與送出的請求。
/// - Throws: 迴圈拋出的錯誤。
private func pollOnce(uploadStatus: Int, packing packedOutput: String) async throws -> (JobCycle, [HTTPRequest]) {
	let transport: RoutingTransport = .init(uploadStatus: uploadStatus)
	let loop: JobPollingLoop = .init(
		client: .init(transport: transport),
		backend: backend(packing: packedOutput),
		reporter: .init(client: .init(transport: transport), wait: { _ in }),
		uploader: .init(client: .init(transport: transport), wait: { _ in }),
		configuration: pollingLoopConfiguration
	)
	let cycle: JobCycle = try await loop.poll(cursor: nil)
	return (cycle, transport.requests.withLock { $0 })
}

/// 是不是送終態的那一次回寫（帶 `state`、且不是 `running`）。
///
/// - Parameter request: 送出的請求。
/// - Returns: 是終態回寫時為 true。
private func isTerminalUpdate(_ request: HTTPRequest) -> Bool {
	guard
		request.method == "PUT",
		let data: Data = request.body
	else { return false }
	// 這裡只分辨是不是終態回寫、不負責斷言：解不開的本體就不是，不必記成測試失敗。
	let object: Any? = try? JSONSerialization.jsonObject(with: data)
	guard let body: [String: Any] = object as? [String: Any] else { return false }
	return (body["state"] as? String).map { $0 != "running" } ?? false
}

// MARK: - JobPollingLoopArtifactTests

/// 迴圈把 job 跑完之後的產物上傳接上：送不送、什麼時候送、送失敗時終態怎麼改。
private final class JobPollingLoopArtifactTests {

	/// 帶回產物就在送終態之前上傳，用這件 job 的專屬 token；上傳成功時終態照舊是成功。
	@Test
	private func `uploads the collected artifacts before the final state`() async throws {
		let (cycle, requests): (JobCycle, [HTTPRequest]) = try await pollOnce(
			uploadStatus: 201,
			packing: "labcontroller-packed \(archive.count)\n"
		)
		guard case let .handled(_, outcome, _) = cycle.disposition else {
			Issue.record("這一輪應該收下並經手了那件 job")
			return
		}
		#expect(outcome == .completed)
		let uploadIndex: Int = try #require(requests.firstIndex { $0.url.path.hasSuffix("/jobs/7/artifacts") })
		let terminalIndex: Int = try #require(requests.firstIndex(where: isTerminalUpdate))
		#expect(uploadIndex < terminalIndex)
		#expect(requests[uploadIndex].method == "POST")
		#expect(requests[uploadIndex].headers["JOB-TOKEN"] == "synthetic-job-token")
		#expect(try requestBody(of: requests[terminalIndex])["state"] as? String == "success")
	}

	/// 上傳一直送不上去時，本來成功的 job 改判失敗、分類為不重試。
	@Test
	private func `fails a green job whose artifacts cannot be uploaded`() async throws {
		let (cycle, requests): (JobCycle, [HTTPRequest]) = try await pollOnce(
			uploadStatus: 500,
			packing: "labcontroller-packed \(archive.count)\n"
		)
		guard case let .handled(_, outcome, _) = cycle.disposition else {
			Issue.record("這一輪應該收下並經手了那件 job")
			return
		}
		#expect(outcome == .jobFailed)
		#expect(requests.count(where: { $0.url.path.hasSuffix("/artifacts") }) == JobArtifactUploader.attemptLimit)
		let terminal: HTTPRequest = try #require(requests.first(where: isTerminalUpdate))
		#expect(try requestBody(of: terminal)["state"] as? String == "failed")
		#expect(try requestBody(of: terminal)["failure_reason"] as? String == "script_failure")
	}

	/// 一個檔案都沒有符合時沒有東西要送：不敲上傳端點，job 照樣成功。
	@Test
	private func `sends nothing when no file matches`() async throws {
		let (cycle, requests): (JobCycle, [HTTPRequest]) = try await pollOnce(
			uploadStatus: 201,
			packing: "labcontroller-packed none\n"
		)
		guard case let .handled(_, outcome, _) = cycle.disposition else {
			Issue.record("這一輪應該收下並經手了那件 job")
			return
		}
		#expect(outcome == .completed)
		#expect(!requests.contains { $0.url.path.hasSuffix("/artifacts") })
	}
}

// MARK: - JobPollingLoopUploadStepTests

/// 跑完之後那一步單獨看：取消、沒有產物、job 已失敗三種情況下送不送。
private final class JobPollingLoopUploadStepTests {

	/// 一份收成的產物。
	private let collected: CollectedArtifact = .init(declaration: .init(name: "build", paths: ["build"]), archive: archive)

	/// 站台已經取消這件 job 時不送，只在 trace 留一行；終態不改。
	@Test
	private func `does not upload once the server has canceled the job`() async {
		let transport: RoutingTransport = .init(uploadStatus: 201)
		let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "done\n", artifacts: [collected])
		let uploaded: JobRunReport = await JobPollingLoop.uploadingArtifacts(
			of: report,
			with: .init(client: .init(transport: transport), wait: { _ in }),
			to: syntheticReportTarget,
			masker: .init(maskedValues: []),
			canceled: true
		)
		#expect(transport.requests.withLock { $0 }.isEmpty)
		#expect(uploaded.outcome == .completed)
		#expect(uploaded.trace.hasSuffix("產物不上傳。\n"))
	}

	/// 沒有產物時不碰上傳器，結果原樣交回。
	@Test
	private func `leaves a report without artifacts untouched`() async {
		let transport: RoutingTransport = .init(uploadStatus: 201)
		let report: JobRunReport = .init(outcome: .completed, exitCode: 0, trace: "done\n")
		let uploaded: JobRunReport = await JobPollingLoop.uploadingArtifacts(
			of: report,
			with: .init(client: .init(transport: transport), wait: { _ in }),
			to: syntheticReportTarget,
			masker: .init(maskedValues: []),
			canceled: false
		)
		#expect(transport.requests.withLock { $0 }.isEmpty)
		#expect(uploaded == report)
	}

	/// job 已經失敗時照送（帶回來的是 `on_failure`／`always` 的產物），死因保留原本的那一個。
	@Test
	private func `uploads after a failure and keeps the original cause`() async {
		let transport: RoutingTransport = .init(uploadStatus: 500)
		let report: JobRunReport = .init(
			outcome: .systemFailed,
			failureReason: .runnerSystemFailure,
			trace: "boom\n",
			artifacts: [collected]
		)
		let uploaded: JobRunReport = await JobPollingLoop.uploadingArtifacts(
			of: report,
			with: .init(client: .init(transport: transport), wait: { _ in }),
			to: syntheticReportTarget,
			masker: .init(maskedValues: []),
			canceled: false
		)
		#expect(transport.requests.withLock { $0 }.count == JobArtifactUploader.attemptLimit)
		#expect(uploaded.outcome == .systemFailed)
		#expect(uploaded.failureReason == .runnerSystemFailure)
	}
}
