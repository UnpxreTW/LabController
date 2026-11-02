//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Logging
import Synchronization
import Testing

// MARK: - KeepaliveTransport

/// 依序播放的假傳輸，序列裡可以排連不上的那一次。
///
/// 全部為合成資料（假 id／token／站台位址）。序列耗盡後重複最後一步。
private final class KeepaliveTransport: HTTPTransport, Sendable {

	/// 以步驟序列建立。
	///
	/// - Parameter steps: 依序播放的步驟。
	fileprivate init(_ steps: [Step]) {
		self.steps = .init(steps)
	}

	/// 一次呼叫要發生什麼。
	fileprivate enum Step {

		/// 回這個回應。
		case respond(HTTPResponse)

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
		case let .respond(response): return response
		case .fail: throw URLError(.notConnectedToInternet)
		}
	}

	/// 待播放的步驟序列。
	private let steps: Mutex<[Step]>
}

/// 回報座標；全為合成值。
private let target: JobReportTarget = .init(
	host: "https://gitlab.example.invalid",
	identifier: 7,
	token: "synthetic-job-token"
)

/// 站台照常收下回報的回應（執行中的 job，不帶 `Job-Status`）。
private let running: HTTPResponse = .init(statusCode: 200)

// MARK: - JobKeepaliveTests

/// 跑 job 期間的定期回報：什麼時候喊停、什麼時候不喊停。
private final class JobKeepaliveTests {

	/// 站台回 403 時喊停並收手：那是站台端說這件 job 已不在執行中，再報下去只會一直被擋。
	@Test
	private func `stops the job when the server answers forbidden`() async throws {
		let transport: KeepaliveTransport = .init([.respond(running), .respond(.init(statusCode: 403))])
		let cancellation: StopSignal = .init()
		let keepalive: JobKeepalive = .init(client: .init(transport: transport), target: target, wait: { _ in })
		await keepalive.run(signaling: cancellation, logger: .init(label: "test"))
		#expect(cancellation.isStopped)
		// 第一次照常、第二次被擋就收手，不再送第三次。
		let requests: [HTTPRequest] = transport.requests.withLock { $0 }
		#expect(requests.count == 2)
		let update: HTTPRequest = try #require(requests.last)
		#expect(update.method == "PUT")
		#expect(update.url.path.hasSuffix("/jobs/7"))
		let payload: Data = try #require(update.body)
		let body: [String: Any] = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
		#expect(body["state"] as? String == "running")
		// 回報用的是這件 job 的專屬 token，runner 認證 token 不出現在這條路徑上。
		#expect(body["token"] as? String == "synthetic-job-token")
	}

	/// 狀態碼照常、但 `Job-Status` 標頭寫著已取消時同樣喊停：判準看回應帶了什麼，不看站台版本。
	@Test
	private func `stops the job when the server reports it canceled`() async {
		let canceled: HTTPResponse = .init(statusCode: 200, headers: ["Job-Status": "canceled"])
		let transport: KeepaliveTransport = .init([.respond(canceled)])
		let cancellation: StopSignal = .init()
		let keepalive: JobKeepalive = .init(client: .init(transport: transport), target: target, wait: { _ in })
		await keepalive.run(signaling: cancellation, logger: .init(label: "test"))
		#expect(cancellation.isStopped)
		#expect(transport.requests.withLock { $0.count } == 1)
	}

	/// 連線失敗不喊停：站台暫時不在不代表 job 被取消，下一輪照常再送。
	@Test
	private func `keeps the job running through a transport failure`() async {
		let transport: KeepaliveTransport = .init([.fail, .respond(running), .respond(.init(statusCode: 403))])
		let cancellation: StopSignal = .init()
		let lines: Mutex<[String]> = .init([])
		let levels: Mutex<[Logger.Level]> = .init([])
		// 每一輪等待時記下那一刻訊號的狀態：連不上之後的那一輪，訊號必須還沒被按下。
		let stoppedBeforeEachWait: Mutex<[Bool]> = .init([])
		let keepalive: JobKeepalive = .init(client: .init(transport: transport), target: target, wait: { _ in
			stoppedBeforeEachWait.withLock { $0.append(cancellation.isStopped) }
		})
		let logger: Logger = CapturingLogHandler.logger { level, line in
			lines.withLock { $0.append(line) }
			levels.withLock { $0.append(level) }
		}
		await keepalive.run(signaling: cancellation, logger: logger)
		#expect(stoppedBeforeEachWait.withLock { $0 } == [false, false, false])
		#expect(transport.requests.withLock { $0.count } == 3)
		#expect(cancellation.isStopped)
		let warnings: [String] = messages(at: .warning, levels: levels.withLock { $0 }, lines: lines.withLock { $0 })
		#expect(warnings.first?.contains("job 7 keepalive failed") == true)
		// 連線失敗那一行不得帶出 job token。
		#expect(!lines.withLock { $0 }.contains { $0.contains("synthetic-job-token") })
	}

	/// 站台一直照常收下時一直報下去、不喊停，直到上層把這一支收掉。
	@Test
	private func `keeps reporting while the job is running`() async {
		let transport: KeepaliveTransport = .init([.respond(running)])
		let cancellation: StopSignal = .init()
		let waits: Mutex<Int> = .init(0)
		let keepalive: JobKeepalive = .init(client: .init(transport: transport), target: target, wait: { _ in
			let count: Int = waits.withLock { count in
				count += 1
				return count
			}
			// 第四輪起停在這裡，等上層取消：真的睡一小時，被取消時立刻回來。
			guard count > 3 else { return }
			try? await Task.sleep(for: .seconds(3600))
		})
		let keeping: Task<Void, Never> = .init { await keepalive.run(signaling: cancellation, logger: .init(label: "test")) }
		while waits.withLock({ $0 }) < 4 {
			await Task.yield()
		}
		keeping.cancel()
		await keeping.value
		#expect(transport.requests.withLock { $0.count } == 3)
		#expect(!cancellation.isStopped)
	}

	/// 間隔收在一秒到十分鐘之間，等待時拿到的是收過的那個值。
	@Test
	private func `clamps the interval between one second and ten minutes`() async {
		let transport: KeepaliveTransport = .init([.respond(.init(statusCode: 403))])
		let client: JobRequestClient = .init(transport: transport)
		let waited: Mutex<[TimeInterval]> = .init([])
		let long: JobKeepalive = .init(client: client, target: target, interval: 3600, wait: { seconds in
			waited.withLock { $0.append(seconds) }
		})
		#expect(long.interval == 600)
		#expect(JobKeepalive(client: client, target: target, interval: 0).interval == 1)
		#expect(JobKeepalive(client: client, target: target).interval == 60)
		await long.run(signaling: .init(), logger: .init(label: "test"))
		#expect(waited.withLock { $0 } == [600])
	}
}
