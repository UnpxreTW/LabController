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

/// 等待被叫醒才算數的上限：真的睡滿的話會是好幾十秒，差距大到不必卡在毫秒級。
private let wakeUpBudget: TimeInterval = 5

/// 交出去跑的那段工作最多撐多久：取消打得斷的話一步都撐不到。
///
/// 這道上限是給「打不斷」那條失敗路徑的煞車——沒有它的話，那不是一條轉紅的測試，是整個測試
/// 套件掛在那裡等。
private let cancellationBudget: TimeInterval = 10

// MARK: - StopSignalTests

private final class StopSignalTests {

	/// 喊停之後的等待一秒都不等。
	@Test
	private func `does not wait at all once stopped`() async {
		let signal: StopSignal = .init()
		signal.stop()
		#expect(signal.isStopped)
		let startedAt: Date = .init()
		await signal.wait(600)
		#expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
	}

	/// 等待途中喊停會把它叫醒，不必等睡滿。
	@Test
	private func `wakes a wait that is already in flight`() async throws {
		let signal: StopSignal = .init()
		let startedAt: Date = .init()
		async let waited: Void = signal.wait(600)
		// 讓上面那段等待先真的進到睡眠裡，喊停才是「途中」而不是「開始前」。
		try await Task.sleep(for: .milliseconds(50))
		signal.stop()
		await waited
		#expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
	}

	/// 沒被喊停就照樣等：叫醒的是喊停，不是每次呼叫都立刻回來。
	@Test
	private func `still waits while nobody has called stop`() async {
		let signal: StopSignal = .init()
		let startedAt: Date = .init()
		await signal.wait(0.2)
		#expect(Date().timeIntervalSince(startedAt) >= 0.2)
		#expect(!signal.isStopped)
	}

	/// 呼叫端被取消時等待也要醒：等待跑在另一顆 Task 上，取消不會自己傳過去。
	@Test
	private func `wakes when the caller itself is cancelled`() async throws {
		let signal: StopSignal = .init()
		let startedAt: Date = .init()
		let waiting: Task<Void, Never> = .init { await signal.wait(600) }
		try await Task.sleep(for: .milliseconds(50))
		waiting.cancel()
		await waiting.value
		#expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
		// 取消的是呼叫端、不是喊停：旗標照舊沒翻。
		#expect(!signal.isStopped)
	}

	/// 喊停會把交出去跑的在飛工作直接取消。
	@Test
	private func `cancels work that is already in flight`() async throws {
		let signal: StopSignal = .init()
		let startedAt: Date = .init()
		let running: Task<Bool, Never> = .init {
			do {
				try await signal.cancelWhenStopped { try await Task.sleep(for: .seconds(cancellationBudget)) }
				return false
			} catch {
				return true
			}
		}
		// 讓上面那段工作先真的跑起來，喊停才是「途中」而不是「開始前」。
		try await Task.sleep(for: .milliseconds(50))
		signal.stop()
		#expect(await running.value)
		#expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
	}

	/// 喊停之後交出去的工作一步都不跑。
	@Test
	private func `refuses to start work once stopped`() async {
		let signal: StopSignal = .init()
		let started: Mutex<Bool> = .init(false)
		signal.stop()
		await #expect(throws: CancellationError.self) {
			try await signal.cancelWhenStopped { started.withLock { $0 = true } }
		}
		#expect(!started.withLock { $0 })
	}

	/// 沒被喊停就照常跑完並把值帶回來：取消的是喊停，不是每次呼叫都當場作廢。
	@Test
	private func `runs work to completion while nobody has called stop`() async throws {
		let signal: StopSignal = .init()
		let value: Int = try await signal.cancelWhenStopped { 7 }
		#expect(value == 7)
		// 跑完就撤登記：之後喊停不該再碰到它，重複喊停也不出事。
		signal.stop()
		signal.stop()
		#expect(signal.isStopped)
	}

	/// 喊停之後才等的話一秒都不等：寬限要從喊停那一刻起算，早到的等待不能白等一輪。
	@Test
	private func `returns at once from untilStopped when already stopped`() async {
		let signal: StopSignal = .init()
		signal.stop()
		let startedAt: Date = .init()
		await signal.untilStopped()
		#expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
	}

	/// 等在那裡的看門會被喊停叫醒。
	@Test
	private func `wakes untilStopped when stop arrives`() async throws {
		let signal: StopSignal = .init()
		let startedAt: Date = .init()
		let watching: Task<Void, Never> = .init { await signal.untilStopped() }
		// 讓上面那顆真的停進等待裡，喊停才是「途中」而不是「開始前」。
		try await Task.sleep(for: .milliseconds(50))
		signal.stop()
		await watching.value
		#expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
	}

	/// 沒被喊停就不回來：看門等的是喊停，不是每次呼叫都當場放行。
	///
	/// 這一條立著，寬限才有意義——看門一被呼叫就回來的話，每件 job 一開跑就被判逾時。
	@Test
	private func `keeps waiting in untilStopped while nobody has called stop`() async throws {
		let signal: StopSignal = .init()
		let finished: Mutex<Bool> = .init(false)
		let watching: Task<Void, Never> = .init {
			await signal.untilStopped()
			finished.withLock { $0 = true }
		}
		try await Task.sleep(for: .milliseconds(100))
		#expect(!finished.withLock { $0 })
		signal.stop()
		await watching.value
		#expect(finished.withLock { $0 })
	}

	/// 呼叫端被取消時看門也要醒：job 正常跑完時撤看門走的就是這條，醒不過來就撤不掉。
	@Test
	private func `wakes untilStopped when the caller itself is cancelled`() async throws {
		let signal: StopSignal = .init()
		let startedAt: Date = .init()
		let watching: Task<Void, Never> = .init { await signal.untilStopped() }
		try await Task.sleep(for: .milliseconds(50))
		watching.cancel()
		await watching.value
		#expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
		// 取消的是呼叫端、不是喊停：旗標照舊沒翻。
		#expect(!signal.isStopped)
	}

	/// 旗標一開始是關的，喊停後翻起來，重複喊停不出事。
	@Test
	private func `flips the flag and tolerates repeated stops`() {
		let signal: StopSignal = .init()
		#expect(!signal.isStopped)
		signal.stop()
		signal.stop()
		#expect(signal.isStopped)
	}
}
