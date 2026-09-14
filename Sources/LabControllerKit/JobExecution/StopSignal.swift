//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

/// 一支可以被喊停、而且喊停時會把正在等待的人叫醒的停止訊號。
///
/// 只用旗標表示停止的話，喊停與「有人發現被喊停」之間隔著整段退避等待：領件迴圈在沒有工作
/// 時會退開 ``JobPollingLoop/Configuration/retryInterval`` 秒，那段等待期間旗標翻了也沒人看，
/// 行程要等睡滿才結束。服務管理器給的收工寬限比那段等待短時，閒著的行程每一次停止都以逾時
/// 強殺收場，從來沒有一次是自己收工的。
///
/// 本型別把「旗標」與「等待」接在一起：``stop()`` 除了翻旗標，還會把此刻登記在案的取消動作
/// 逐一按下——包含停在 ``wait(_:)`` 裡的等待，以及交給 ``cancelWhenStopped(_:)`` 跑的在飛
/// 工作。取消**只落在那些另開的 Task 上**，不會傳進呼叫端——正在跑的 job 不因此被從中間丟下。
public final class StopSignal: Sendable {

	// MARK: Public

	/// 是否已被喊停；領件迴圈每一輪開始前問的就是這一個。
	public var isStopped: Bool {
		state.withLock { $0.isStopped }
	}

	/// 喊停：翻旗標，並把此刻登記在案的取消動作全部按下。
	///
	/// 可重複呼叫，也可以從訊號處理器那種非 async 的地方呼叫。
	public func stop() {
		let cancellations: [@Sendable () -> Void] = state.withLock { state in
			state.isStopped = true
			let registered: [@Sendable () -> Void] = .init(state.cancellations.values)
			state.cancellations.removeAll()
			return registered
		}
		for cancellation in cancellations {
			cancellation()
		}
	}

	/// 等指定秒數，中途被喊停就立刻回來。
	///
	/// 已經被喊停時一秒都不等。等待本身跑在另開的一顆 Task 裡，``stop()`` 取消的是它；
	/// 呼叫端被取消時同樣叫得醒——那顆 Task 會跟著被取消，與直接 `Task.sleep` 的行為一致。
	///
	/// - Parameter seconds: 最多等多久。
	public func wait(_ seconds: TimeInterval) async {
		guard !isStopped else { return }
		let identifier: UUID = .init()
		let sleeper: Task<Void, Never> = .init { try? await Task.sleep(for: .seconds(seconds)) }
		// 另開 Task 與登記之間可能剛好被喊停；登記在鎖內重問一次旗標，那一槍才不會落空。
		let stoppedMeanwhile: Bool = state.withLock { state in
			guard !state.isStopped else { return true }
			state.cancellations[identifier] = { sleeper.cancel() }
			return false
		}
		if stoppedMeanwhile { sleeper.cancel() }
		// 呼叫端被取消時也要醒：等待跑在另一顆 Task 上，取消不會自己傳過去。
		await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
		state.withLock { $0.cancellations[identifier] = nil }
	}

	/// 在一顆可以被喊停取消的子 Task 裡跑一段工作。
	///
	/// 給那種自己不看旗標、只吃 Task 取消的工作用：在飛的領件就是這種形狀——連線 hold 多久由
	/// 站台端決定，喊停時沒人打斷它的話，行程要等回應自己回來才有機會收工。
	///
	/// - Important: 已經被喊停時一步都不跑，直接拋 `CancellationError`；呼叫端自己被取消時，取消
	///   照樣傳得進去。
	///
	/// - Warning: 工作要吃得下取消才有意義——`URLSession` 的 async 形狀吃得下，丟進阻塞佇列的那
	///   種不吃。
	///
	/// - Parameter operation: 要跑的工作。
	/// - Returns: 工作的回傳值。
	/// - Throws: 工作自己拋的錯誤；喊停打斷時為取消類錯誤。
	public func cancelWhenStopped<Value: Sendable>(
		_ operation: @escaping @Sendable () async throws -> Value
	) async throws -> Value {
		guard !isStopped else { throw CancellationError() }
		let identifier: UUID = .init()
		let work: Task<Value, any Error> = .init { try await operation() }
		// 另開 Task 與登記之間可能剛好被喊停；登記在鎖內重問一次旗標，那一槍才不會落空。
		let stoppedMeanwhile: Bool = state.withLock { state in
			guard !state.isStopped else { return true }
			state.cancellations[identifier] = { work.cancel() }
			return false
		}
		if stoppedMeanwhile { work.cancel() }
		defer { state.withLock { $0.cancellations[identifier] = nil } }
		// 呼叫端被取消時也要傳進去：工作跑在另一顆 Task 上，取消不會自己傳過去。
		return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
	}

	/// 建立一支尚未被喊停的訊號。
	public init() {}

	// MARK: Private

	/// 旗標與此刻登記在案的等待。
	private struct State {

		/// 是否已被喊停。
		var isStopped: Bool = false

		/// 登記在案的取消動作，以識別碼登記，等完或跑完即撤下。
		internal var cancellations: [UUID: @Sendable () -> Void] = [:]
	}

	/// 受鎖保護的內部狀態。
	private let state: Mutex<State> = .init(.init())

}
