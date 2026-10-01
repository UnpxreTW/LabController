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

	/// 起一邊看門：等到它那一邊到期，就把那場競賽收成給定的那一種、並焚毀環境。
	///
	/// 兩邊（停止寬限、時間預算）到期之後要做的事一模一樣，差別只在等的是什麼、收成哪一種
	/// ⇒ 寫成一支收在這裡。等待以閉包收進來而不是收一個 `Task`：停止寬限那一邊接的是全程共用的
	/// 那一份，時間預算那一邊等的是一段時長，兩者沒有共同的形狀。
	///
	/// - Important: **先收場、再焚毀**。焚毀一開始，停在環境裡的那道命令就回得來——後端把被收掉的
	///   命令收成「環境不在」⇒ 反過來寫的話，焚毀還在等對面回覆的那整段時間裡，工作那一條會先跑完
	///   並把這一場收成 ``RunRace/Outcome/ranToEnd``，到期那一票於是被丟棄：一件跑飛的 job 回報成
	///   環境問題，而站台端照環境層的政策再派它一次。收場擺在前面不會漏掉環境——
	///   ``ExecutionBackend/withGuest(_:do:)`` 自己那一次焚毀無論如何都會跑到，而同一個環境焚毀
	///   兩次不算錯。
	///
	/// - Parameters:
	///   - guest: 到期時要焚毀的環境。
	///   - expiry: 等到那一邊到期為止。
	///   - race: 要收的那一場。
	///   - outcome: 到期時把那一場收成哪一種。
	/// - Returns: 這一邊的看門；呼叫端負責在離開前取消它。
	internal func watchdog(
		destroying guest: GuestIdentifier,
		after expiry: @escaping @Sendable () async -> Void,
		settling race: RunRace,
		as outcome: RunRace.Outcome
	) -> Task<Void, Never> {
		.init {
			await expiry()
			guard !Task.isCancelled else { return }
			// 收場擺在焚毀之前，理由見上方說明。
			race.settle(outcome)
			// 焚毀失敗也照樣放手：留下來的環境在 `ps()` 上看得到，而繼續等下去只會等到被強殺。
			try? await backend.destroy(guest)
		}
	}

	/// 誰先到算誰的等待點：工作自己跑到底、與任一邊看門先到，第一個交進來的結果算數。
	///
	/// 不用 task group 收這場競賽——離開 group 之前要等全部子任務結束，而送進環境的那道命令不吃
	/// Task 取消，等於沒有寬限。
	internal final class RunRace: Sendable {

		/// 這一場的三種收法。
		internal enum Outcome {

			/// 等待的那一邊自己走完：跑 job 時＝工作跑到底（不論成敗），等容量時＝等滿了一輪。
			case ranToEnd

			/// 收到停止訊號、寬限也用完：跑 job 時環境已焚毀，等容量時環境還沒開起來。
			case aborted

			/// 這件 job 的時間預算用完：環境已焚毀。
			///
			/// 與 ``aborted`` 分開而不是共用一種：兩者的終態不同（逾時 vs 環境層失敗），而站台端
			/// 對兩者的重試政策也不相同——收成同一種等於讓一個跑飛的 job 被當成環境問題再派一次。
			case timedOut
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
