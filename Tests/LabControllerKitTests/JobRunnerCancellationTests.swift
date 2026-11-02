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

// MARK: - JobRunnerCancellationTests

/// 站台取消 job 時那條看門線；與停止寬限、時間預算兩條分檔，各自看得完。
private final class JobRunnerCancellationTests {

	/// 測試共用的基底。
	private let image: GuestImage = .alias("ci-linux")

	/// 測試共用的取碼座標。
	private let git: GitInfo = .init(repoURL: "https://gitlab.example/group/project.git", ref: "main", sha: "deadbeef")

	/// 執行中被站台取消時當場焚毀環境，不等那道已經送進去的命令自己回來。
	@Test
	private func `destroys the guest when the server cancels a running job`() async throws {
		let backend: BlockingExecutionBackend = .init()
		let plan: JobPlan = .init(
			jobIdentifier: 4,
			git: git,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		let lines: Mutex<[String]> = .init([])
		let levels: Mutex<[Logger.Level]> = .init([])
		// 取消的時機由測試給：命令一送進環境就算取消，不靠睡也不靠真的回報。
		let runner: JobRunner = .init(
			backend: backend,
			abortWhenCanceled: { await backend.untilFirstCommand() },
			logger: CapturingLogHandler.logger { level, line in
				lines.withLock { $0.append(line) }
				levels.withLock { $0.append(level) }
			}
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .systemFailed)
		#expect(report.failureReason == .runnerSystemFailure)
		#expect(report.trace.contains("站台已取消這件 job"))
		// 與停止寬限那一行分得開：事後要查得出環境是誰收掉的。
		#expect(!report.trace.contains("收到停止訊號"))
		let warnings: [String] = messages(at: .warning, levels: levels.withLock { $0 }, lines: lines.withLock { $0 })
		#expect(warnings.contains { $0.contains("job 4 was canceled by the server; destroyed guest") })
		#expect(backend.inner.destroyCount >= 1)
		#expect(try await backend.ps().isEmpty)
		// 停住的那道命令要放掉，否則它會留到整個測試行程結束。
		backend.release()
	}

	/// 等容量的期間被站台取消時不再開環境：那件 job 站台端已經不要了。
	@Test
	private func `stops waiting for capacity once the server cancels the job`() async {
		let inner: InMemoryExecutionBackend = .init()
		let backend: CapacityLimitedBackend = .init(inner: inner, refusals: 99)
		let plan: JobPlan = .init(
			jobIdentifier: 5,
			git: git,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		// 這道閘不開＝那一輪等待永遠等不完，於是只剩「取消」這一邊交得出結果。
		let waiting: TestGate = .init()
		let lines: Mutex<[String]> = .init([])
		let levels: Mutex<[Logger.Level]> = .init([])
		let runner: JobRunner = .init(
			backend: backend,
			abortWhenCanceled: {},
			waitBeforeRetry: { _ in await waiting.wait() },
			logger: CapturingLogHandler.logger { level, line in
				lines.withLock { $0.append(line) }
				levels.withLock { $0.append(level) }
			}
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .systemFailed)
		#expect(report.failureReason == .runnerSystemFailure)
		#expect(report.trace.contains("等容量的期間站台取消了這件 job"))
		#expect(backend.spawnAttempts == 1)
		let warnings: [String] = messages(at: .warning, levels: levels.withLock { $0 }, lines: lines.withLock { $0 })
		#expect(warnings == ["job 5 was canceled by the server while waiting for capacity"])
		// 一個環境都沒開成，也就沒有東西要收。
		#expect(inner.destroyCount == 0)
		// 放掉停在等待裡的那一輪，否則它會留到整個測試行程結束。
		waiting.open()
	}

	/// 沒被取消的 job 看門一步都不動：環境照正常路徑焚毀一次，結果也不被改寫。
	@Test
	private func `leaves a job that is never canceled untouched`() async throws {
		let backend: InMemoryExecutionBackend = .init()
		let plan: JobPlan = .init(
			jobIdentifier: 6,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		// 這道閘不開＝站台從頭到尾沒取消，看門於是一直停在等待裡。
		let cancellation: TestGate = .init()
		let runner: JobRunner = .init(backend: backend, abortWhenCanceled: { await cancellation.wait() })
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(report.exitCode == 0)
		#expect(backend.destroyCount == 1)
		#expect(try await backend.ps().isEmpty)
		cancellation.open()
	}
}
