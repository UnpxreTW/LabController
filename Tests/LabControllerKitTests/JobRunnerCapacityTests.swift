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

/// 從兩份平行收集的紀錄裡取出某一個等級的那幾行。
///
/// 與 ``JobRunnerTests`` 同形：收行的出口一次交出等級與內容兩樣，而測試要斷言的是「這個等級
/// 寫了哪幾行」；兩份各自收在自己的鎖裡，在這裡才對起來。
///
/// - Parameters:
///   - level: 要取哪一個等級。
///   - levels: 依序收下的等級；由呼叫端先自鎖裡取出。
///   - lines: 依序收下的內容；同上。
/// - Returns: 該等級的那幾行，順序同寫出時。
private func messages(at level: Logger.Level, of levels: [Logger.Level], _ lines: [String]) -> [String] {
	zip(levels, lines).filter { $0.0 == level }.map(\.1)
}

// MARK: - JobRunnerCapacityTests

/// 後端沒有餘裕時那條等待線；與 ``JobRunnerTests`` 分檔，兩邊各自看得完。
private final class JobRunnerCapacityTests {

	/// 測試共用的基底。
	private let image: GuestImage = .alias("ci-linux")

	/// 測試共用的取碼座標。
	private let git: GitInfo = .init(repoURL: "https://gitlab.example/group/project.git", ref: "main", sha: "deadbeef")

	/// 後端說當下沒有餘裕時等一等再問，而不是把這件 job 當場判紅。
	@Test
	private func `waits for capacity instead of failing the job`() async throws {
		let inner: InMemoryExecutionBackend = .init()
		let backend: CapacityLimitedBackend = .init(inner: inner, refusals: 2)
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			git: git,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		// 等待由測試接走：要驗的是「等了幾次、每次等多久」，睡真的那段時間只會讓測試變慢。
		let waited: Mutex<[Duration]> = .init([])
		let runner: JobRunner = .init(backend: backend, waitBeforeRetry: { interval in
			waited.withLock { $0.append(interval) }
		})
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(report.exitCode == 0)
		#expect(backend.spawnAttempts == 3)
		// 寫死 15 秒而不是拿 `JobRunner.capacityRetryInterval` 來比：拿它比等於拿被測的那個值
		// 當答案，改掉常數兩邊一起變、這一條就看不出差別。
		#expect(waited.withLock { $0 } == [.seconds(15), .seconds(15)])
		#expect(JobRunner.capacityRetryInterval == .seconds(15))
		// 等的那段時間要在 trace 上看得見，否則那件 job 只是看起來跑得特別久。
		#expect(report.trace.contains("執行環境暫時沒有餘裕"))
		#expect(report.trace.contains("已經等到容量"))
		#expect(inner.destroyCount == 1)
	}

	/// 這件 job 的時間預算用完仍等不到容量時收成環境層失敗——站台端讀得懂、會另派一台重跑。
	@Test
	private func `gives up waiting for capacity when the job budget runs out`() async throws {
		let inner: InMemoryExecutionBackend = .init()
		let backend: CapacityLimitedBackend = .init(inner: inner, refusals: 99)
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			git: git,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 60
		)
		// 一問一步的假時鐘：等一輪之後時間就超過上限，不靠睡去逼近它。
		let clock: SteppingClock = .init(step: 45)
		let runner: JobRunner = .init(backend: backend, waitBeforeRetry: { _ in }, now: clock.now)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .systemFailed)
		#expect(report.failureReason == .runnerSystemFailure)
		#expect(report.trace.contains("等不到容量"))
		// 一個環境都沒開成，也就沒有東西要收。
		#expect(inner.destroyCount == 0)
		#expect(try await backend.ps().isEmpty)
	}

	/// 等容量的期間收到停止訊號、寬限也用完時就地放手：環境還沒開起來，看門線也還沒起來。
	@Test
	private func `stops waiting for capacity once the stop grace runs out`() async throws {
		let inner: InMemoryExecutionBackend = .init()
		let backend: CapacityLimitedBackend = .init(inner: inner, refusals: 99)
		let plan: JobPlan = .init(
			jobIdentifier: 3,
			git: git,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		// 這道閘不開＝那一輪等待永遠等不完，於是只剩「喊停」這一邊交得出結果。
		let waiting: TestGate = .init()
		let lines: Mutex<[String]> = .init([])
		let levels: Mutex<[Logger.Level]> = .init([])
		let runner: JobRunner = .init(
			backend: backend,
			abortAfterStop: {},
			waitBeforeRetry: { _ in await waiting.wait() },
			logger: CapturingLogHandler.logger { level, line in
				lines.withLock { $0.append(line) }
				levels.withLock { $0.append(level) }
			}
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .systemFailed)
		#expect(report.failureReason == .runnerSystemFailure)
		#expect(report.trace.contains("等容量的期間收到停止訊號"))
		let warnings: [String] = messages(at: .warning, of: levels.withLock { $0 }, lines.withLock { $0 })
		#expect(warnings.count == 1)
		#expect(warnings.first?.contains("job 3 gave up waiting for capacity") == true)
		#expect(inner.destroyCount == 0)
		// 放掉停在等待裡的那一輪，否則它會留到整個測試行程結束。
		waiting.open()
	}

	/// 後端明確拒絕的那一類不等也不重試：再問幾次答案都一樣，等只是把 job 的預算耗掉。
	@Test
	private func `does not wait for a request the backend refuses outright`() async throws {
		let inner: InMemoryExecutionBackend = .init()
		let backend: CapacityLimitedBackend = .init(
			inner: inner, refusals: 1, error: .requestRejected(detail: "golden_not_found：golden alias not found: x")
		)
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			git: git,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		let waited: Mutex<[Duration]> = .init([])
		let runner: JobRunner = .init(backend: backend, waitBeforeRetry: { interval in
			waited.withLock { $0.append(interval) }
		})
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .systemFailed)
		#expect(report.failureReason == .runnerSystemFailure)
		#expect(backend.spawnAttempts == 1)
		#expect(waited.withLock { $0 }.isEmpty)
		#expect(!report.trace.contains("執行環境暫時沒有餘裕"))
	}

	/// 等容量的那幾輪共用同一份寬限：正式路徑的寬限是「等到喊停之後再睡一段」，每輪重起就永遠
	/// 等不完，收到停止訊號的行程會一路等到這件 job 的預算用完。
	@Test
	private func `arms the stop grace once across every capacity wait`() async throws {
		let inner: InMemoryExecutionBackend = .init()
		let backend: CapacityLimitedBackend = .init(inner: inner, refusals: 99)
		let plan: JobPlan = .init(
			jobIdentifier: 5,
			git: git,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 300
		)
		// 這道閘不開＝那份寬限永遠等不完，於是數的是「它被起了幾次」而不是「誰先回來」。
		let grace: TestGate = .init()
		let armed: Mutex<Int> = .init(0)
		let clock: SteppingClock = .init(step: 45)
		let runner: JobRunner = .init(
			backend: backend,
			abortAfterStop: {
				armed.withLock { $0 += 1 }
				await grace.wait()
			},
			waitBeforeRetry: { _ in },
			now: clock.now
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .systemFailed)
		#expect(report.trace.contains("等不到容量"))
		// 等了三輪才用完預算，而寬限只該起一次。
		#expect(armed.withLock { $0 } == 1)
		// 放掉停在等待裡的那份寬限，否則它會留到整個測試行程結束。
		grace.open()
	}

	/// 等到容量、進了環境之後接的仍是同一份寬限：在那裡另起一份等於讓它從頭再睡一段，喊停到真正
	/// 放手的上限變成「等容量那段」加上「一整段寬限」。
	@Test
	private func `keeps the same stop grace once capacity opens up`() async throws {
		let inner: InMemoryExecutionBackend = .init()
		let backend: CapacityLimitedBackend = .init(inner: inner, refusals: 1)
		let plan: JobPlan = .init(
			jobIdentifier: 6,
			git: git,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		// 這道閘不開＝那份寬限等不完，於是數的是「它被起了幾次」而不是「誰先回來」。
		let grace: TestGate = .init()
		let armed: Mutex<Int> = .init(0)
		let runner: JobRunner = .init(
			backend: backend,
			abortAfterStop: {
				armed.withLock { $0 += 1 }
				await grace.wait()
			},
			waitBeforeRetry: { _ in }
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(backend.spawnAttempts == 2)
		// 等過一輪容量、之後進了環境，而那份寬限自始至終只該有一份。
		#expect(armed.withLock { $0 } == 1)
		// 放掉停在等待裡的那份寬限，否則它會留到整個測試行程結束。
		grace.open()
	}
}
