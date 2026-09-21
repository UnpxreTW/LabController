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

/// 前幾次開環境一律拒絕，之後原樣轉給裡面那個後端。
///
/// 要測的是「開不起來時等一等再試」，而真實後端要拒絕得看當下有幾台在跑——那是測不準的。
/// 拒絕幾次由測試排定，開環境試了幾次也記在這裡，兩者對得起來才看得出重試真的發生過。
internal final class CapacityLimitedBackend: ExecutionBackend {

	/// 以裡面那個後端、要拒絕幾次、以及拒絕時拋什麼建立。
	///
	/// - Parameters:
	///   - inner: 拒絕完之後真正做事的後端。
	///   - refusals: 前幾次開環境要拒絕。
	///   - error: 拒絕時拋的錯；預設是「當下沒有餘裕」。
	internal init(
		inner: InMemoryExecutionBackend,
		refusals: Int,
		error: ExecutionBackendError = .capacityUnavailable(detail: "admission_denied：no capacity")
	) {
		self.inner = inner
		self.error = error
		self.state = .init(.init(remainingRefusals: refusals))
	}

	/// 開環境被試了幾次，含被拒絕的那幾次。
	internal var spawnAttempts: Int {
		state.withLock { $0.attempts }
	}

	/// 前幾次一律拒絕，之後照常開。
	internal func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
		let refuses: Bool = state.withLock { state in
			state.attempts += 1
			guard state.remainingRefusals > 0 else { return false }
			state.remainingRefusals -= 1
			return true
		}
		if refuses { throw error }
		return try await inner.spawn(specification)
	}

	/// 原樣轉交。
	internal func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
		try await inner.exec(command, in: guest)
	}

	/// 原樣轉交。
	internal func ps() async throws -> [GuestSummary] {
		try await inner.ps()
	}

	/// 原樣轉交。
	internal func status(of guest: GuestIdentifier) async throws -> GuestSummary {
		try await inner.status(of: guest)
	}

	/// 原樣轉交。
	internal func destroy(_ guest: GuestIdentifier) async throws {
		try await inner.destroy(guest)
	}

	/// 拒絕完之後真正做事的後端。
	private let inner: InMemoryExecutionBackend

	/// 拒絕時拋的錯。
	private let error: ExecutionBackendError

	/// 拒絕的計數；開環境可能來自不同的執行脈絡，故上鎖。
	private struct State {

		/// 還要拒絕幾次。
		internal var remainingRefusals: Int

		/// 開環境被試了幾次。
		internal var attempts: Int = 0
	}

	/// 上鎖的計數。
	private let state: Mutex<State>
}
