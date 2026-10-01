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

// MARK: - TestGate

/// 一道只開一次的閘：開之前停在那裡，開了之後每一次等待都直接過。
///
/// 停止寬限那幾條路徑要的是「事件推事件」而不是睡幾毫秒碰運氣——時間換來的測試在忙碌的機器上
/// 會偶發轉紅，而偶發轉紅的測試最後都被當成雜訊略過。
internal final class TestGate: Sendable {

	/// 開閘，並把停在等待裡的全部放行；重複開不出事。
	internal func open() {
		let waiting: [CheckedContinuation<Void, Never>] = state.withLock { state in
			state.isOpen = true
			defer { state.waiting = [] }
			return state.waiting
		}
		for continuation in waiting {
			continuation.resume()
		}
	}

	/// 等到開閘為止；已經開了就立刻回來。
	internal func wait() async {
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			let openedAlready: Bool = state.withLock { state in
				guard !state.isOpen else { return true }
				state.waiting.append(continuation)
				return false
			}
			if openedAlready { continuation.resume() }
		}
	}

	/// 閘的狀態。
	private struct State {

		/// 開過了沒。
		internal var isOpen: Bool = false

		/// 停在等待裡的接續。
		internal var waiting: [CheckedContinuation<Void, Never>] = []
	}

	/// 受鎖保護的內部狀態。
	private let state: Mutex<State> = .init(.init())

}

// MARK: - BlockingExecutionBackend

/// 命令送進去就停在那裡、直到測試放行才結束的後端。
///
/// 停止寬限要對付的正是這個形狀：真正的 ``ExecutionBackend/exec(_:in:)`` 送進環境之後不吃 Task
/// 取消，寬限用完時沒有任何辦法叫它回來。命令停住之後再也不會自己結束，寬限那一邊於是穩定地
/// 先到——測試不必靠時間長短來分勝負。
///
/// - Important: 用完必須呼叫 ``release()``，否則那一顆停住的 Task 會留到整個測試行程結束。
internal final class BlockingExecutionBackend: ExecutionBackend {

	/// 以記帳用的後端建立。
	///
	/// - Parameters:
	///   - inner: 記帳與其餘四個動作交給它。
	///   - passingThrough: 前幾道命令照記帳後端排好的答案回；之後那一道才停住。要測「某個步驟
	///     先失敗、下一個步驟才跑飛」時，失敗那幾道必須真的跑得完。
	///   - holdingFirstDestroy: 第一次焚毀停在那裡、等第二次焚毀來了才放行。要測「看門線收場與
	///     工作跑完誰先到」時，這是把看門線那一邊按住的辦法。
	internal init(
		inner: InMemoryExecutionBackend = .init(),
		passingThrough: Int = 0,
		holdingFirstDestroy: Bool = false
	) {
		self.inner = inner
		self.passingThrough = passingThrough
		self.holdingFirstDestroy = holdingFirstDestroy
	}

	/// 記帳與其餘四個動作都交給它。
	internal let inner: InMemoryExecutionBackend

	/// 等到停住的那一道命令真的送進環境為止；喊停的時機要落在 job 執行中，這是那個錨。
	internal func untilFirstCommand() async {
		await commandStarted.wait()
	}

	/// 放行停住的那道命令；它隨即以「環境不在」結束，與焚毀之後的真實行為一致。
	internal func release() {
		released.open()
	}

	/// 照常開一台環境，交給記帳用的後端。
	internal func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
		try await inner.spawn(specification)
	}

	/// 前幾道命令照常跑完，之後那一道通知「已經送進去了」並停住等測試放行。
	internal func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
		let index: Int = seen.withLock { count in
			defer { count += 1 }
			return count
		}
		guard index >= passingThrough else { return try await inner.exec(command, in: guest) }
		commandStarted.open()
		await released.wait()
		throw ExecutionBackendError.unknownGuest(guest)
	}

	/// 照常列環境，交給記帳用的後端。
	internal func ps() async throws -> [GuestSummary] {
		try await inner.ps()
	}

	/// 照常查環境狀態，交給記帳用的後端。
	internal func status(of guest: GuestIdentifier) async throws -> GuestSummary {
		try await inner.status(of: guest)
	}

	/// 焚毀環境，交給記帳用的後端；``holdingFirstDestroy`` 開著時第一次焚毀先停在那裡。
	///
	/// 停住的那一次先放掉那道命令（環境被收掉之後它就回得來，與真實後端一致），再等第二次焚毀
	/// 來把它放行。放行交給「下一次焚毀」而不是交給測試自己：那兩次焚毀誰先進來不由這裡決定，
	/// 而寫成「第一次停住、第二次放行」時兩種順序都走得完。
	internal func destroy(_ guest: GuestIdentifier) async throws {
		if holdingFirstDestroy {
			let isFirst: Bool = hasHeldDestroy.withLock { hasHeld in
				defer { hasHeld = true }
				return !hasHeld
			}
			if isFirst {
				released.open()
				await destroyHold.wait()
			} else {
				destroyHold.open()
			}
		}
		try await inner.destroy(guest)
	}

	/// 前幾道命令照常跑；這個數字之後那一道才停住。
	private let passingThrough: Int

	/// 第一次焚毀要不要停在那裡等第二次。
	private let holdingFirstDestroy: Bool

	/// 已經有一次焚毀停在那裡了沒。
	private let hasHeldDestroy: Mutex<Bool> = .init(false)

	/// 第二次焚毀開這道閘，把停住的第一次放行。
	private let destroyHold: TestGate = .init()

	/// 收到過幾道命令。
	private let seen: Mutex<Int> = .init(0)

	/// 停住的那一道命令送進環境時開。
	private let commandStarted: TestGate = .init()

	/// 測試放行停住的命令時開。
	private let released: TestGate = .init()

}
