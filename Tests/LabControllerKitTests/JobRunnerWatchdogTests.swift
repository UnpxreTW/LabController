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

// MARK: - JobRunnerWatchdogTests

private final class JobRunnerWatchdogTests {

	/// 測試共用的基底。
	private let image: GuestImage = .alias("ci-linux")

	/// 時間預算在一個步驟跑到一半時用完：焚毀環境、以逾時收場。
	///
	/// 「不再開始下一個步驟」那道判斷擋不住一道已經送進環境的命令——這條與執行並行的看門線才是
	/// 唯一收得掉它的那一條。
	@Test
	private func `destroys the guest when the time budget runs out mid step`() async throws {
		let backend: BlockingExecutionBackend = .init()
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		// 預算用完的那一刻由測試給：命令一送進環境就算用完，不靠睡也不靠把時鐘推過去。
		let runner: JobRunner = .init(
			backend: backend,
			waitUntilDeadline: { _ in await backend.untilFirstCommand() }
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .timeout)
		#expect(report.failureReason == .jobExecutionTimeout)
		#expect(report.trace.contains("已達本次 job 的時間上限"))
		#expect(report.trace.contains("執行環境已焚毀"))
		// 環境真的被收掉了：這件事不能只寫在結果裡，不然留下來的是一台沒人收的 guest。
		#expect(backend.inner.destroyCount >= 1)
		#expect(try await backend.ps().isEmpty)
		// 停住的那道命令要放掉，否則它會留到整個測試行程結束。
		backend.release()
	}

	/// job 在預算之內跑完時看門一步都不動：結果不被改寫成逾時，環境照正常路徑焚毀一次。
	///
	/// 順帶釘住看門等的是**剩下的**預算而不是宣告值：開環境與等容量吃的是同一份額度，等滿宣告值
	/// 等於讓每件 job 多拿一段。
	@Test
	private func `leaves a job that finishes within its budget untouched`() async throws {
		let backend: InMemoryExecutionBackend = .init()
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		// 這道閘不開＝預算永遠沒用完，看門於是從頭到尾停在等待裡。
		let budget: TestGate = .init()
		let waited: Mutex<Duration?> = .init(nil)
		// 每問一次走 20 秒的時鐘：開環境那一刻是第二次問（第一次是時間原點）⇒ 剩下的預算恰是
		// 宣告值減一步。數字寫死才擋得住「等的其實是宣告值」這種寫法。
		let clock: SteppingClock = .init(step: 20)
		let runner: JobRunner = .init(
			backend: backend,
			waitUntilDeadline: { remaining in
				waited.withLock { $0 = remaining }
				await budget.wait()
			},
			now: clock.now
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(report.exitCode == 0)
		#expect(backend.destroyCount == 1)
		#expect(try await backend.ps().isEmpty)
		let remaining: Duration = try #require(waited.withLock { $0 })
		#expect(remaining == .seconds(580))
		// 放掉停在等待裡的看門，理由同上一條。
		budget.open()
	}

	/// 已經有步驟失敗過，看門線才在下一個步驟中途到期：死因是那個失敗、不是逾時。
	///
	/// 站台端對逾時與 job 自己紅了的重試政策不同 ⇒ 用收尾的樣子蓋掉真正的原因，等於讓一件本來
	/// 該紅的 job 被當成跑不完再派一次。步驟邊界那一道判斷早就這樣收，看門線這一條收法要一致。
	@Test
	private func `keeps the step failure as the cause when the watchdog fires mid step`() async throws {
		// 第一道命令回結束碼 4、第二道才停住：`when: always` 的收拾步驟正是在失敗之後才跑的那一個。
		let inner: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			command.last?.hasSuffix("step-0.sh") == true ? .init(command: command, exitCode: 4) : nil
		}))
		let backend: BlockingExecutionBackend = .init(inner: inner, passingThrough: 1)
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [
				.init(name: "script", script: ["swift build"]),
				.init(name: "after_script", script: ["cleanup"], runCondition: .always)
			],
			timeoutSeconds: 600
		)
		let runner: JobRunner = .init(
			backend: backend,
			waitUntilDeadline: { _ in await backend.untilFirstCommand() }
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .jobFailed)
		#expect(report.failureReason == .scriptFailure)
		#expect(report.exitCode == 4)
		// 環境照樣焚毀、逾時照樣寫進 trace：改的只是回報出去的死因。
		#expect(report.trace.contains("已達本次 job 的時間上限"))
		#expect(inner.destroyCount >= 1)
		// 停住的那道命令要放掉，否則它會留到整個測試行程結束。
		backend.release()
	}

	/// 預算用完時先把競賽收場、才焚毀環境：焚毀期間那道被收掉的命令回來了，也蓋不掉逾時那一票。
	///
	/// 焚毀要跟對面來回一趟（真環境以秒計），而停在環境裡的那道命令在環境被收掉的那一刻就回得來
	/// ⇒ 收場擺在焚毀之後的話，工作那一條會在這段空檔裡先跑完、把這一場收成跑到底，這件跑飛的
	/// job 於是回報成環境問題、被站台端照環境層的政策再派一次。
	@Test
	private func `settles the race before destroying the guest`() async throws {
		// 第一次焚毀停住＝看門線被按在那裡，工作那一條因此有整段空檔可以搶著收場。
		let backend: BlockingExecutionBackend = .init(holdingFirstDestroy: true)
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [.init(name: "script", script: ["swift build"])],
			timeoutSeconds: 600
		)
		let runner: JobRunner = .init(
			backend: backend,
			waitUntilDeadline: { _ in await backend.untilFirstCommand() }
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		// 搶輸的那一票是「跑到底」，而它一路收成的是環境層失敗 ⇒ 這兩行分得出兩種順序。
		#expect(report.outcome == .timeout)
		#expect(report.failureReason == .jobExecutionTimeout)
		#expect(report.trace.contains("已達本次 job 的時間上限"))
		// 環境照樣被收掉：這一條改的是收場的順序，不是少收一台 guest。
		#expect(backend.inner.destroyCount >= 1)
		#expect(try await backend.ps().isEmpty)
		// 停住的那道命令由焚毀自己放掉（見 `holdingFirstDestroy`），這裡不必再放一次。
	}
}
