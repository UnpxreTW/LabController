//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Synchronization

/// ``JobRunner`` 那場「誰先到算誰的」等待。
///
/// 與 ``JobRunner`` 本體分開擺的理由同 ``JobRunner/TraceRecorder``：這是一份自己上鎖、自己
/// 收斂的狀態，而 ``JobRunner`` 是一個值型別的流程；擺在一起時，流程那一側看起來像是自己
/// 握著狀態。
extension JobRunner {

	/// 誰先到算誰的等待點：工作自己跑到底、與停止寬限用完，第一個交進來的結果算數。
	///
	/// 不用 task group 收這場競賽——離開 group 之前要等全部子任務結束，而送進環境的那道命令不吃
	/// Task 取消，等於沒有寬限。
	internal final class RunRace: Sendable {

		/// 這一場的兩種收法。
		internal enum Outcome {

			/// 等待的那一邊自己走完：跑 job 時＝工作跑到底（不論成敗），等容量時＝等滿了一輪。
			case ranToEnd

			/// 收到停止訊號、寬限也用完：跑 job 時環境已焚毀，等容量時環境還沒開起來。
			case aborted
		}

		/// 交一個結果進來；第一個算數，其餘丟棄。
		internal func settle(_ outcome: Outcome) {
			let pending: CheckedContinuation<Outcome, Never>? = state.withLock { state in
				guard state.outcome == nil else { return nil }
				state.outcome = outcome
				defer { state.continuation = nil }
				return state.continuation
			}
			pending?.resume(returning: outcome)
		}

		/// 等第一個結果；已經有結果就立刻回來。
		internal func outcome() async -> Outcome {
			await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
				let settled: Outcome? = state.withLock { state in
					guard let outcome: Outcome = state.outcome else {
						state.continuation = continuation
						return nil
					}
					return outcome
				}
				if let settled { continuation.resume(returning: settled) }
			}
		}

		/// 這一場的狀態。
		private struct State {

			/// 第一個交進來的結果；還沒有人交進來時為 nil。
			internal var outcome: Outcome?

			/// 停在 ``outcome()`` 裡的接續。
			internal var continuation: CheckedContinuation<Outcome, Never>?
		}

		/// 受鎖保護的內部狀態。
		private let state: Mutex<State> = .init(.init())
	}
}
