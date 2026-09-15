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
	internal init(inner: InMemoryExecutionBackend = .init()) {
		self.inner = inner
	}

	/// 記帳與其餘四個動作都交給它。
	internal let inner: InMemoryExecutionBackend

	/// 等到第一道命令真的送進環境為止；喊停的時機要落在 job 執行中，這是那個錨。
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

	/// 通知「已經送進去了」，然後停住等測試放行。
	internal func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
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

	/// 照常焚毀環境，交給記帳用的後端。
	internal func destroy(_ guest: GuestIdentifier) async throws {
		try await inner.destroy(guest)
	}

	/// 第一道命令送進環境時開。
	private let commandStarted: TestGate = .init()

	/// 測試放行停住的命令時開。
	private let released: TestGate = .init()

}
