//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

/// ``JobRunner`` 那份 trace 抄本，連同抄本上的分段時間表。
///
/// 與 ``JobRunner`` 本體分開擺：抄本是一份自己上鎖、自己累積的狀態，而 ``JobRunner`` 是一個
/// 值型別的流程；兩者混在同一個檔裡時，流程那一側看起來像是自己握著狀態。
extension JobRunner {

	/// 一份逐段遮蔽、逐段累積的 trace 抄本。
	///
	/// 做成參考型別是因為它要跨越 ``ExecutionBackend/withGuest(_:do:)`` 的閉包邊界——工作在
	/// 裡面寫、收拾之後在外面還要再寫一行，兩邊必須是同一份，否則環境開不起來時那一段說明
	/// 會連同抄本一起消失。
	internal final class TraceRecorder: Sendable {

		/// 以遮蔽規則建立。
		internal init(masker: TraceMasker) {
			self.state = .init(.init(stream: .init(masker: masker)))
		}

		/// 寫一行；空字串不寫，免得 trace 裡多出成排的空行。
		internal func write(_ line: String) {
			guard !line.isEmpty else { return }
			state.withLock { state in
				state.released += state.stream.append(line + "\n")
			}
		}

		/// 收攏並取回全文；緩衝區裡押著的尾巴在此放行。
		///
		/// 放行的內容併回已放行的那份，所以收攏之後還能再寫、再收一次——收拾階段還要補一行的
		/// 那條路徑走的就是這個。
		internal func finish() -> String {
			state.withLock { state in
				state.released += state.stream.flush()
				return state.released
			}
		}

		/// 緩衝器與已放行的內容。
		///
		/// 上鎖是因為寬限那條路徑會讓兩邊同時寫：寬限到期時 ``JobRunner`` 就地收尾並補一行，而
		/// 被放手的那段工作仍在環境裡跑、跑完還會再寫幾行。
		private struct State {

			/// 跨段遮蔽的緩衝器。
			internal var stream: MaskedTraceStream

			/// 已放行的內容。
			internal var released: String = ""

			/// 分段標記的時間原點；還沒開始跑時為 nil。
			internal var origin: Date?
		}

		/// 受鎖保護的內部狀態。
		private let state: Mutex<State>
	}
}

// MARK: - JobRunner.TraceRecorder + 分段時間表

/// 抄本上的那張分段時間表：跟「寫一行 trace」是兩件事，分開擺才看得出哪些行是給機器讀的。
extension JobRunner.TraceRecorder {

	/// 寫下一段的標記；第一段同時把時間原點定在這一刻。
	///
	/// 原點與第一段是同一刻、同一次取時刻：分成兩次取會讓第一段的 `elapsed` 落在一個沒有意義的
	/// 小數上，而那個數字看起來像「這一段花了多久」。
	///
	/// **格式刻意固定**：這幾行是要在事後被 `grep` 出來排成一張時間表的，而不是給人一行行讀的。
	/// 段名放在時刻之前、且不含空白（步驟走索引、名字由緊接著的 `$ ` 那一行給），欄位因此切得開。
	///
	/// - Parameters:
	///   - stage: 段名。
	///   - instant: 這一刻。
	internal func mark(_ stage: String, at instant: Date) {
		let origin: Date = state.withLock { state in
			let origin: Date = state.origin ?? instant
			state.origin = origin
			return origin
		}
		let elapsed: String = .init(format: "%.3f", instant.timeIntervalSince(origin))
		write("[lab_controller] stage=\(stage) t=\(instant.formatted(.iso8601)) elapsed=\(elapsed)s")
	}
}
