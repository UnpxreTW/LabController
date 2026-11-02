//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Synchronization

/// ``JobRunner`` 記第一個失敗步驟的那個盒子。
///
/// 與 ``JobRunner`` 本體分開擺的理由同 ``JobRunner/TraceRecorder``：這是一份自己上鎖、自己
/// 收斂的狀態，而 ``JobRunner`` 是一個值型別的流程。
extension JobRunner {

	/// 裝第一個失敗步驟的結束碼的盒子；看門線在步驟中途收場時據它定死因。
	///
	/// 與 ``FinishedRun`` 分開、而且自己上鎖：這一份要跨執行緒——寫的是跑步驟那一條線，讀的是
	/// 看門線收場之後的 ``runOrAbort(_:in:on:before:from:recording:progress:)``，而
	/// ``FinishedRun`` 全程只有跑 job 那一條線自己碰。
	internal final class FirstFailure: Sendable {

		/// 第一個失敗步驟的結束碼；沒有步驟失敗過、或失敗只發生在封存之後時為 nil。
		internal var exitCode: Int32? {
			state.withLock { $0.exitCode }
		}

		/// 記下第一個失敗的結束碼；後續的失敗、以及封存之後的失敗都不改寫它。
		internal func record(_ exitCode: Int32) {
			state.withLock { state in
				guard
					!state.isSealed,
					state.exitCode == nil
				else { return }
				state.exitCode = exitCode
			}
		}

		/// 封存：這一刻之後記進來的失敗不算。
		///
		/// 預算用完的那一刻環境就被焚毀，而環境沒了之後那道命令仍可能以非零結束碼回來（後端把
		/// 被收掉的命令回成一份結果、不是一個錯）。那個結束碼是焚毀造成的，把它當死因等於用
		/// 收尾的樣子蓋掉真正的原因——與這個盒子要修的方向恰好相反。
		internal func seal() {
			state.withLock { $0.isSealed = true }
		}

		/// 盒子的狀態。
		private struct State {

			/// 第一個失敗步驟的結束碼。
			internal var exitCode: Int32?

			/// 封存過沒有。
			internal var isSealed: Bool = false
		}

		/// 受鎖保護的內部狀態。
		private let state: Mutex<State> = .init(.init())
	}
}
