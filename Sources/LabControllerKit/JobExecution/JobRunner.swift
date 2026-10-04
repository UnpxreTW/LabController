//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Logging
import Synchronization

/// 把一份消化過的 payload 在一個一次性執行環境裡跑完，回報怎麼收的。
///
/// 接的是 ``JobAdmission`` 收下的 ``JobPlan``，用的是 ``ExecutionBackend`` 那五個動作，
/// 中間隔著 ``JobWorkspace`` 鋪出來的檔案樹。**這一層不碰站台**：trace 與終態怎麼回寫是
/// ``JobRequestClient`` 那一側的事，兩者分開才能各自對著假的另一半測。
///
/// **時間上限兩處在看**：步驟與步驟之間各看一次，決定還要不要開始下一個；另有一條與執行並行
/// 的看門線，在預算用完的那一刻焚毀整個環境。兩條都要——協議沒有取消，送進環境的那道命令不吃
/// Task 取消，所以「不再開始新的步驟」擋不住一個已經跑飛的命令，而只靠看門線則要等到預算真的
/// 用完，明明可以早一點收的 job 會多佔一段格子。
/// 連帶的一個缺口一併寫明：**逾時之後連 `when: always` 的收拾步驟也不跑**——那類步驟要有
/// 意義就得自帶一份不受本次預算約束的時間，而那份預算取多少沒有依據可訂。在它有依據之前，
/// 這裡寧可誠實地不跑，也不要給一個沒有盡頭的收拾階段。
///
/// **紀錄與 trace 是兩份、寫的東西也不同**：trace 是要交回站台的那一份，逐行帶著 job 自己的
/// 輸出；紀錄留在跑這件 job 的機器上，只寫這一層自身的狀態——環境開不起來、環境焚毀不掉、
/// 寬限用完把環境收掉。這幾件事在 trace 裡也有，但 trace 送不回站台的那一刻就一起消失，而
/// 那正是最需要在機器上查得到的時候。
///
/// **trace 上另有一張分段時間表**：檔案樹鋪好、環境開起來、取碼、每一個真的跑到的步驟、以及
/// 收尾，各留一行 `[lab_controller] stage=<段名> t=<時刻> elapsed=<秒>s`。存在理由是一件 job
/// 只回報一個終態時，跑了三十分鐘與跑了七十秒長得一模一樣——事後查不出那段時間落在哪裡。段名
/// 不含空白、欄位以空白切開，是要讓這幾行事後被 `grep` 出來直接排成一張表；步驟因此走索引而
/// 不是名字（名字由緊接著的 `$ ` 那一行給）。略過的步驟不留行：時間表上多一段沒發生過的事，
/// 讀表的人會去找它。
///
/// - Important: 紀錄行一律不帶變數值、命令與命令輸出；錯誤一律經
///   ``GitLabAPIError/safeDescription(of:)`` 收斂，收斂後仍可能內插 payload 帶進來的字串
///   （例如變數名），因此再經 ``JobPlan/masker`` 遮蔽一次才寫。
public struct JobRunner: Sendable {

	// MARK: Public

	/// 用哪個後端開環境。
	public let backend: any ExecutionBackend

	/// 本機這一側的設定。
	public let configuration: JobRunnerConfiguration

	/// 後端說沒有餘裕時，隔多久再問一次。
	///
	/// 固定值、不做成設定：這個數字要對齊的是「等另一件 job 跑完」的量級，而真正決定等多久的
	/// 是這件 job 自己的時間預算——等待吃的是它的額度。多一個旋鈕就多一個要與預算對齊的地方，
	/// 而對不齊時的症狀（等到預算用完）與現在沒有兩樣。
	public static let capacityRetryInterval: Duration = .seconds(15)

	/// 開一個環境、取碼、逐步驟跑完，然後把環境焚毀。
	///
	/// **後端說沒有餘裕時會等**：那一則（``ExecutionBackendError/capacityUnavailable(detail:)``）
	/// 講的是「現在沒有空位」而不是「這個請求不成立」，隔一段時間再送多半就開得起來。等待吃的是
	/// 這件 job 自己的時間預算，等到預算用完仍開不起來才收成環境層失敗。環境一旦開起來就不再重
	/// 試——那之後的步驟可能已經把東西推出去了，整件重跑會做第二次。
	///
	/// - Parameters:
	///   - plan: 消化過的 payload。
	///   - image: 要從哪一份基底開環境。
	/// - Returns: 這次的結果；跑不成也是一份結果、不拋。
	public func run(_ plan: JobPlan, on image: GuestImage) async -> JobRunReport {
		let trace: TraceRecorder = .init(masker: plan.masker)
		for warning in plan.warnings {
			trace.write(warning.traceMessage)
		}
		let workspace: JobWorkspace
		do {
			workspace = try .init(plan: plan, root: configuration.workspaceRoot)
		} catch {
			// 錯誤訊息內插的是變數名而不是值，但仍走遮蔽通道——「這條路徑上應該沒有秘密」
			// 是一種會過期的推論，而過期的那一次就是秘密上站台的那一次。
			trace.write("執行環境的檔案準備不起來：\(error)")
			logger.error(
				"""
				job \(plan.jobIdentifier) workspace unusable: \
				\(plan.masker.mask(GitLabAPIError.safeDescription(of: error)))
				"""
			)
			return .init(outcome: .systemFailed, failureReason: .runnerSystemFailure, trace: trace.finish(),
			             warnings: plan.warnings)
		}
		// 時間原點與時間上限取同一刻：分開取的話，事後把各段的 `elapsed` 與「還剩多少預算」擺在
		// 一起看會差一小段，而對不上的那一小段正是最花時間去確認的東西。
		let startedAt: Date = now()
		let deadline: Date = startedAt.addingTimeInterval(.init(plan.timeoutSeconds))
		trace.mark("workspace", at: startedAt)
		let specification: GuestSpecification = .init(image: image, injectedFiles: workspace.injectedFiles)
		return await runInGuest(plan, in: workspace, as: specification, before: deadline, recording: trace)
	}

	/// 逐欄建立。
	///
	/// - Parameters:
	///   - backend: 執行後端。
	///   - configuration: 本機設定。
	///   - abortAfterStop: 收到停止訊號、寬限也用完時才回來的等待；不給即不設寬限。
	///   - waitBeforeRetry: 後端說沒有餘裕時，再問一次之前的那段等待；不給即真的等那麼久。
	///   - waitUntilDeadline: 看門線在焚毀環境之前的那段等待；不給即真的等到預算用完。
	///   - logger: 紀錄出口；不給即取行程裝上的那一份。這一層只送出紀錄、不決定它們寫去哪裡。
	///   - now: 取當下時刻的方式。
	public init(
		backend: any ExecutionBackend,
		configuration: JobRunnerConfiguration = .init(),
		abortAfterStop: (@Sendable () async -> Void)? = nil,
		// try? 吞掉的只有取消：等待被中斷＝不必再等，往下那一圈自己會看時限，呼叫端不需要知道原因。
		waitBeforeRetry: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
		waitUntilDeadline: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
		logger: Logger = .init(label: "lab-controller"),
		now: @escaping @Sendable () -> Date = Date.init
	) {
		self.backend = backend
		self.configuration = configuration
		self.abortAfterStop = abortAfterStop
		self.waitBeforeRetry = waitBeforeRetry
		self.waitUntilDeadline = waitUntilDeadline
		self.logger = logger
		self.now = now
	}

	// MARK: Private

	/// 裝一份「工作已經跑完」的結果的盒子。
	///
	/// 存在理由與 ``TraceRecorder`` 同：``ExecutionBackend/withGuest(_:do:)`` 在工作正常結束、
	/// 焚毀卻失敗時拋的是焚毀那個錯，於是閉包的回傳值到不了外面。沒有這個盒子，一件跑完的 job
	/// 會被收拾階段的錯蓋成系統層失敗。
	private final class FinishedRun {

		/// 工作跑完的結果；工作自己拋出時為 nil。
		var report: JobRunReport?

		/// 這次有沒有等過容量；等過才在環境開起來時補一行「等到了」。
		var hasWaitedForCapacity: Bool = false

		/// 喊停之後那段寬限的等待；第一次要用時才起，等容量的每一輪與環境開起來之後都共用同一份。
		///
		/// 各起一份會讓寬限從頭算起：正式路徑的那份等待是「等到喊停，再睡一段寬限」，而喊停多半
		/// 發生在開始等之前或等的期間 ⇒ 再起一份就是再睡滿一段。等容量那幾輪若各起一份，寬限
		/// （以秒計）多半比問一次的間隔長、永遠等不到它回來，收到停止訊號的行程會一路等到這件 job
		/// 的預算用完；先等過容量再進環境時若另起一份，喊停到真正放手的上限變成「等到容量那段」
		/// 加上「一整段寬限」。
		var stopGrace: Task<Void, Never>?

		/// 環境開起來、工作進去過沒有。
		///
		/// 容量那條重試線只在這之前有效：進去過就表示步驟可能已經跑了（甚至已經推了東西出去），
		/// 那之後再整件重來會做第二次。`report` 當不了這個旗標——工作自己拋出時它仍是 nil。
		var entered: Bool = false
	}

	/// 裝第一個失敗步驟的結束碼的盒子；看門線在步驟中途收場時據它定死因。
	///
	/// 與 ``FinishedRun`` 分開、而且自己上鎖：這一份要跨執行緒——寫的是跑步驟那一條線，讀的是
	/// 看門線收場之後的 ``runOrAbort(_:in:on:before:from:recording:progress:)``，而
	/// ``FinishedRun`` 全程只有跑 job 那一條線自己碰。
	private final class FirstFailure: Sendable {

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

	/// 收到停止訊號、寬限也用完時才回來的等待；nil ＝ 不設寬限，job 跑多久就等多久。
	///
	/// - Important: 兩處在看：job 執行中（看門線），以及等後端挪出餘裕的那一段——後者若不看，
	///   收到停止訊號的行程會一路等到這件 job 的預算用完。job 自己的時間上限走的是另一條
	///   （見 ``JobPlan/timeoutSeconds``）。
	private let abortAfterStop: (@Sendable () async -> Void)?

	/// 後端說沒有餘裕時，再問一次之前的那段等待；測試靠它把時間跳過去、不真的睡。
	private let waitBeforeRetry: @Sendable (Duration) async -> Void

	/// 看門線在焚毀環境之前的那段等待；測試靠它把預算用完的那一刻挪到想要的位置、不真的睡。
	///
	/// 與 ``waitBeforeRetry`` 分開：兩者等的是不同的東西（一段固定的間隔 vs 這件 job 剩下的
	/// 預算），而測試多半只想把其中一邊挪走。
	private let waitUntilDeadline: @Sendable (Duration) async -> Void

	/// 這一層的紀錄出口；寫的內容與界線見型別說明。
	private let logger: Logger

	/// 取當下時刻；測試靠它推時鐘，正式路徑取系統時間。
	private let now: @Sendable () -> Date

	/// 等容量的三種收法。
	private enum CapacityWait {

		/// 等滿了一輪，可以再問一次。
		case retry

		/// 這件 job 的時間預算用完了。
		case outOfTime

		/// 等的期間收到停止訊號、寬限也用完了。
		case stopped
	}

	/// 這個錯是不是「後端當下沒有餘裕」。
	///
	/// 寫成一個判斷式而不是在呼叫端直接比對：那裡拿到的是 `any Error`，比對要先轉型再解 case，
	/// 兩層寫在條件句裡會讓「只重試這一種」這件事變得不好讀。
	private static func isCapacityUnavailable(_ error: any Error) -> Bool {
		guard let backendError: ExecutionBackendError = error as? ExecutionBackendError else { return false }
		guard case .capacityUnavailable = backendError else { return false }
		return true
	}

	/// 開一個環境把這件 job 跑完；後端說沒有餘裕時等一等再開一次。
	///
	/// 重試只在「環境還沒開起來」的那一段有效：進去過就表示步驟可能已經跑了（甚至已經推了東西
	/// 出去），那之後整件重來會做第二次。
	///
	/// - Parameters:
	///   - plan: 消化過的 payload。
	///   - workspace: 已鋪好的檔案樹。
	///   - specification: 環境規格。
	///   - deadline: 這件 job 的時間上限。
	///   - trace: 抄本。
	/// - Returns: 這次的結果；開不起來也是一份結果、不拋。
	private func runInGuest(
		_ plan: JobPlan,
		in workspace: JobWorkspace,
		as specification: GuestSpecification,
		before deadline: Date,
		recording trace: TraceRecorder
	) async -> JobRunReport {
		// 跑完的結果先放在這裡，才不會被收拾階段的錯蓋掉：`withGuest` 在工作正常結束、焚毀卻失敗
		// 時拋的是焚毀那個錯，而那時 job 其實已經跑完了。把一件已經做完（甚至已經推了東西出去）的
		// job 回報成「環境錯、可重試」，站台端會整件重跑一次。
		let finished: FinishedRun = .init()
		// 離開這裡＝環境開起來了或已經放手，兩種情況都不再需要那份寬限的等待。
		defer { finished.stopGrace?.cancel() }
		while true {
			do {
				return try await backend.withGuest(specification) { guest in
					// 進到這裡＝環境開起來了，容量那條重試線到此為止。
					finished.entered = true
					if finished.hasWaitedForCapacity { trace.write("已經等到容量，開始跑這件 job。") }
					// 這一刻取一次、兩處用：時間表上「環境開起來」那一段的起點，同時也是看門線算
					// 剩餘預算的基準。各取一次會讓兩者差一小段，而時鐘是注入的、多問一次就多走一步。
					let enteredAt: Date = now()
					trace.mark("guest", at: enteredAt)
					let report: JobRunReport = try await runOrAbort(
						plan,
						in: workspace,
						on: guest,
						before: deadline,
						from: enteredAt,
						recording: trace,
						progress: finished
					)
					finished.report = report
					return report
				}
			} catch {
				guard
					!finished.entered,
					Self.isCapacityUnavailable(error),
					await waitBeforeAnotherGuest(plan, before: deadline, recording: trace, progress: finished)
				else { return report(after: error, plan, recording: trace, progress: finished) }
			}
		}
	}

	/// 環境那一側拋了錯之後怎麼收。
	///
	/// 分成兩種：工作根本沒跑成（環境層失敗），以及工作跑完了、只是收拾沒收成——後者不改寫結果，
	/// 把一件已經做完的 job 回報成可重試會讓站台端整件重跑一次。
	///
	/// - Parameters:
	///   - error: 環境那一側拋的錯。
	///   - plan: 消化過的 payload。
	///   - trace: 抄本。
	///   - finished: 跑到哪裡了。
	/// - Returns: 這次的結果。
	private func report(
		after error: any Error,
		_ plan: JobPlan,
		recording trace: TraceRecorder,
		progress finished: FinishedRun
	) -> JobRunReport {
		guard let report: JobRunReport = finished.report else {
			trace.write("執行環境沒能把事情做成：\(error)")
			logger.error(
				"""
				job \(plan.jobIdentifier) execution environment failed: \
				\(plan.masker.mask(GitLabAPIError.safeDescription(of: error)))
				"""
			)
			// 環境開不起來也算收尾：時間表少了最後一行，讀表的人分不出「這件 job 沒跑到收尾」與
			// 「紀錄斷在半路」。
			trace.mark("finish", at: now())
			return .init(outcome: .systemFailed, failureReason: .runnerSystemFailure, trace: trace.finish(),
			             warnings: plan.warnings)
		}
		// 收拾失敗不改寫結果，但也不吞掉：留下來的環境仍在 `ps()` 上看得到，回收孤兒本來就是後端
		// 那一側的事（見 `ExecutionBackend.withGuest` 的說明）。
		trace.write("環境沒能焚毀：\(error)")
		// 留下來的環境佔著那台機器的資源，而站台端看到的是一件正常收掉的 job ⇒ 只有這一行會指出
		// 「有東西沒收乾淨」。
		logger.error(
			"""
			job \(plan.jobIdentifier) guest could not be destroyed: \
			\(plan.masker.mask(GitLabAPIError.safeDescription(of: error)))
			"""
		)
		return .init(outcome: report.outcome, failureReason: report.failureReason, exitCode: report.exitCode,
		             trace: trace.finish(), warnings: report.warnings)
	}

	/// 等一輪，並把等待的來龍去脈寫進 trace；回報要不要再開一次環境。
	///
	/// - Parameters:
	///   - plan: 消化過的 payload。
	///   - deadline: 這件 job 的時間上限。
	///   - trace: 抄本。
	///   - finished: 跑到哪裡了；第一次等待才寫那一行說明。
	/// - Returns: 還要不要再開一次。
	private func waitBeforeAnotherGuest(
		_ plan: JobPlan,
		before deadline: Date,
		recording trace: TraceRecorder,
		progress finished: FinishedRun
	) async -> Bool {
		if !finished.hasWaitedForCapacity {
			trace.write("執行環境暫時沒有餘裕，等到有容量再開始（這段等待算在本次 job 的時間上限內）。")
			finished.hasWaitedForCapacity = true
		}
		switch await waitForCapacity(before: deadline, progress: finished) {
		case .retry:
			return true

		case .outOfTime:
			trace.write("等不到容量，已達本次 job 的時間上限（\(plan.timeoutSeconds) 秒）。")
			return false

		case .stopped:
			trace.write("等容量的期間收到停止訊號，這件 job 不再開始。")
			logger.warning("job \(plan.jobIdentifier) gave up waiting for capacity after the stop grace")
			return false
		}
	}

	/// 取這件 job 全程共用的那份「喊停之後的寬限」；還沒起過才起。
	///
	/// 等容量與跑 job 兩段都在看它，而正式路徑的那份等待是「等到喊停，再睡一段寬限」⇒ 兩段各起
	/// 一份的話，先等過容量再進環境時寬限等於從頭再算一次，喊停到真正放手的上限變成兩段相加
	/// （見 ``FinishedRun/stopGrace``）。
	///
	/// - Parameters:
	///   - abortAfterStop: 收到停止訊號、寬限也用完時才回來的等待。
	///   - finished: 跑到哪裡了；那份寬限存在它身上。
	/// - Returns: 共用的那一份。
	private func grace(
		waiting abortAfterStop: @escaping @Sendable () async -> Void,
		progress finished: FinishedRun
	) -> Task<Void, Never> {
		let stopGrace: Task<Void, Never> = finished.stopGrace ?? .init { await abortAfterStop() }
		finished.stopGrace = stopGrace
		return stopGrace
	}

	/// 等一輪之後再問一次；回報還能不能再問。
	///
	/// **等的期間也要聽得見停止訊號**：環境還沒開起來，``runOrAbort(_:in:on:before:from:recording:progress:)``
	/// 那條看門線還沒起來，這一段若只是單純地睡，收到停止訊號的行程會一路等到這件 job 的預算
	/// 用完為止——而服務管理器給的收工寬限以秒計，等於回到被強殺的那個樣子。
	///
	/// - Parameters:
	///   - deadline: 這件 job 的時間上限。
	///   - finished: 跑到哪裡了；那份寬限的等待存在它身上，每一輪共用。
	/// - Returns: 還能再問一次、預算用完、或等的期間被喊停。
	private func waitForCapacity(before deadline: Date, progress finished: FinishedRun) async -> CapacityWait {
		guard now() < deadline else { return .outOfTime }
		guard let abortAfterStop: @Sendable () async -> Void = abortAfterStop else {
			await waitBeforeRetry(Self.capacityRetryInterval)
			return now() < deadline ? .retry : .outOfTime
		}
		// 那份寬限只起一次、之後每一輪都等同一份（理由見 `FinishedRun.stopGrace`）。
		let stopGrace: Task<Void, Never> = grace(waiting: abortAfterStop, progress: finished)
		// 這場競賽的兩邊是「等滿一輪」與「喊停之後的寬限也用完」，借的是跑 job 那一段同一個等待點；
		// 時間預算那一邊不在這裡起——環境還沒開起來，沒有東西可焚毀，預算由每一輪回來時自己比對。
		let race: RunRace = .init()
		let waiting: Task<Void, Never> = .init {
			await waitBeforeRetry(Self.capacityRetryInterval)
			race.settle(.ranToEnd)
		}
		let watching: Task<Void, Never> = .init {
			await stopGrace.value
			race.settle(.aborted)
		}
		defer {
			watching.cancel()
			waiting.cancel()
		}
		switch await race.outcome() {
		case .ranToEnd:
			return now() < deadline ? .retry : .outOfTime

		case .aborted:
			return .stopped

		// 這一場沒有起時間預算那一邊，收不到這一種；真收到就當預算用完收——寧可讓這件 job 以逾時
		// 結束，也不要在一條不該走到的路徑上停掉整個行程。
		case .timedOut:
			return .outOfTime
		}
	}

	/// 跑完這件 job，或在停止寬限用完、時間預算用完時就地放手。
	///
	/// - Important: 兩種到期都**不等那段已經送進環境的命令**——``ExecutionBackend/exec(_:in:)``
	///   送進去之後不吃 Task 取消，等它回來等於沒有上限。焚毀環境之後就地回一份結果，那件 job
	///   因此仍回寫得出去、行程也退得了。
	///
	/// - Note: 看門線是常設的：時間預算每件 job 都有，所以這裡總是起一場競賽。停止寬限那一邊
	///   才看有沒有注入 `abortAfterStop`。
	///
	/// - Parameters:
	///   - plan: 消化過的 payload。
	///   - workspace: 已鋪好的檔案樹。
	///   - guest: 已經開好的環境。
	///   - deadline: 這件 job 的時間上限。
	///   - enteredAt: 環境開起來的那一刻；看門線據它算還剩多少預算。
	///   - trace: 抄本。
	///   - finished: 跑到哪裡了；那份寬限存在它身上，等過容量的話這裡接的是同一份。
	/// - Returns: 這次的結果；寬限到期時為環境層失敗，預算用完時為逾時——但預算用完之前已經有
	///   步驟失敗過的話，死因仍是那個失敗。
	/// - Throws: ``ExecutionBackendError``，同 ``execute(_:in:on:before:recording:failing:)``。
	private func runOrAbort(
		_ plan: JobPlan,
		in workspace: JobWorkspace,
		on guest: GuestIdentifier,
		before deadline: Date,
		from enteredAt: Date,
		recording trace: TraceRecorder,
		progress finished: FinishedRun
	) async throws -> JobRunReport {
		let race: RunRace = .init()
		// 失敗過沒有要跨線讀：寫的是下面那條工作線，讀的是看門線收場之後的這裡。
		let failure: FirstFailure = .init()
		let work: Task<JobRunReport, any Error> = .init {
			try await execute(plan, in: workspace, on: guest, before: deadline, recording: trace, failing: failure)
		}
		let finishing: Task<Void, Never> = .init {
			_ = try? await work.value
			race.settle(.ranToEnd)
		}
		let stopWatchdog: Task<Void, Never>? = abortAfterStop.map { abortAfterStop in
			// 等過容量就接那一份、沒等過才在這裡起（理由見 `grace(waiting:progress:)`）。
			let stopGrace: Task<Void, Never> = grace(waiting: abortAfterStop, progress: finished)
			return watchdog(destroying: guest, after: { await stopGrace.value }, settling: race, as: .aborted)
		}
		// 剩下多少預算從環境開起來那一刻算：開環境與等容量吃的是同一份額度，等滿宣告值等於讓每件
		// job 多拿一段。
		let remaining: Duration = .seconds(max(deadline.timeIntervalSince(enteredAt), 0))
		let untilDeadline: @Sendable (Duration) async -> Void = waitUntilDeadline
		let deadlineWatchdog: Task<Void, Never> = watchdog(
			destroying: guest,
			after: {
				await untilDeadline(remaining)
				// 焚毀之前封存：這一刻之後那道命令若以非零結束碼回來，那是被收掉造成的、不是死因。
				failure.seal()
			},
			settling: race,
			as: .timedOut
		)
		defer {
			deadlineWatchdog.cancel()
			stopWatchdog?.cancel()
			finishing.cancel()
		}
		switch await race.outcome() {
		case .ranToEnd:
			return try await work.value
		case .aborted:
			trace.write("收到停止訊號後，這件 job 在寬限之內沒有跑完，執行環境已焚毀。")
			// 帶上環境識別碼：這一行要跟開環境那一側自己的紀錄對得起來，事後才查得出那台被收掉的
			// 環境是哪一台。
			logger.warning("job \(plan.jobIdentifier) exceeded the stop grace; destroyed guest \(guest)")
			return report(plan, outcome: .systemFailed, reason: .runnerSystemFailure, exitCode: nil, trace: trace)
		case .timedOut:
			trace.write("已達本次 job 的時間上限（\(plan.timeoutSeconds) 秒），執行環境已焚毀。")
			logger.warning("job \(plan.jobIdentifier) exceeded its time limit; destroyed guest \(guest)")
			// 已經有步驟失敗過的話，死因是那個失敗、不是逾時——理由與步驟邊界那一道判斷相同：
			// 把終態換成逾時等於用收尾的樣子蓋掉真正的原因，而站台端對兩者的重試政策並不相同。
			guard let exitCode: Int32 = failure.exitCode else {
				return report(plan, outcome: .timeout, reason: .jobExecutionTimeout, exitCode: nil, trace: trace)
			}
			return report(plan, outcome: .jobFailed, reason: .scriptFailure, exitCode: exitCode, trace: trace)
		}
	}

	/// 在已開好的環境裡取碼並逐步驟跑。
	///
	/// - Parameter failure: 第一個失敗步驟的結束碼記在這裡；看門線在步驟中途收場時，死因由它決定
	///   （這個回傳值那時算不得數——那一場競賽已經被看門線收掉，這一條之後交進來的結果一律丟棄）。
	/// - Throws: ``ExecutionBackendError``——那類是「根本沒跑成」，由 ``run(_:on:)`` 收成
	///   ``JobOutcome/systemFailed``；命令自己的非零結束碼不在此列，它是結果。
	private func execute(
		_ plan: JobPlan,
		in workspace: JobWorkspace,
		on guest: GuestIdentifier,
		before deadline: Date,
		recording trace: TraceRecorder,
		failing failure: FirstFailure
	) async throws -> JobRunReport {
		if let checkout: String = workspace.checkoutScriptPath {
			trace.mark("checkout", at: now())
			trace.write("$ 取得程式碼")
			let result: CommandResult = try await backend.exec(command(running: checkout), in: guest)
			trace.write(output(of: result))
			guard result.isSuccess else {
				// 取不到碼算環境錯、不算 job 錯：CI 檔沒有任何一行跑過，紅在這裡不是它的責任，
				// 而站台端對環境錯會重試——下一次多半就取得到了。
				trace.write("取得程式碼失敗（結束碼 \(result.exitCode)），本次一個步驟都不跑。")
				logger.warning(
					"""
					job \(plan.jobIdentifier) could not check out the code on guest \(guest); \
					exit code \(result.exitCode)
					"""
				)
				return report(plan, outcome: .systemFailed, reason: .runnerSystemFailure,
				              exitCode: result.exitCode, trace: trace)
			}
		}
		var hasFailed: Bool = false
		for (index, step) in plan.steps.enumerated() {
			guard step.runCondition.shouldRun(afterFailure: hasFailed) else {
				trace.write("略過步驟 \(step.name)：它的執行條件是 \(step.runCondition.rawValue)。")
				continue
			}
			// 取一次、兩處用：判上限與標這一段的起點講的是同一刻，各取一次會讓時間表上的起點
			// 與真正被拿去比對上限的那一刻對不起來。
			let startingAt: Date = now()
			guard startingAt < deadline else {
				trace.write("已達本次 job 的時間上限（\(plan.timeoutSeconds) 秒），其餘步驟不再開始。")
				// 已經有步驟失敗過的話，死因是那個失敗、不是逾時：把終態換成逾時等於用收尾的
				// 樣子蓋掉真正的原因，而站台端對兩者的重試政策並不相同。
				guard !hasFailed else {
					return report(plan, outcome: .jobFailed, reason: .scriptFailure,
					              exitCode: failure.exitCode, trace: trace)
				}
				return report(plan, outcome: .timeout, reason: .jobExecutionTimeout, exitCode: nil, trace: trace)
			}
			// 段名走索引而不是步驟名：步驟名由 payload 給、帶得進空白，而這幾行要切得開欄位。
			// 讀得懂的那一份名字在緊接著的下一行。
			trace.mark("step[\(index)]", at: startingAt)
			trace.write("$ \(step.name)")
			let result: CommandResult = try await backend.exec(command(running: workspace.stepScriptPaths[index]),
			                                                   in: guest)
			trace.write(output(of: result))
			guard !result.isSuccess else { continue }
			guard !step.allowFailure else {
				trace.write("步驟 \(step.name) 以結束碼 \(result.exitCode) 結束；該步驟允許失敗，繼續往下跑。")
				continue
			}
			trace.write("步驟 \(step.name) 以結束碼 \(result.exitCode) 失敗。")
			hasFailed = true
			failure.record(result.exitCode)
		}
		guard hasFailed else { return report(plan, outcome: .completed, exitCode: 0, trace: trace) }
		return report(plan, outcome: .jobFailed, reason: .scriptFailure, exitCode: failure.exitCode, trace: trace)
	}

	/// 收尾成一份結果；trace 在此刻收攏，之後不再寫入。
	private func report(
		_ plan: JobPlan,
		outcome: JobOutcome,
		reason: JobFailureReason? = nil,
		exitCode: Int32?,
		trace: TraceRecorder
	) -> JobRunReport {
		trace.mark("finish", at: now())
		return .init(outcome: outcome, failureReason: reason, exitCode: exitCode, trace: trace.finish(),
		             warnings: plan.warnings)
	}

	/// 跑一份腳本的完整命令。
	private func command(running script: String) -> [String] {
		configuration.shell + [script]
	}

	/// 一道命令的兩道輸出，先標準輸出、後標準錯誤。
	///
	/// **兩者真正的交錯順序在協議上拿不到**（``CommandResult`` 各收各的），所以這裡是重排過的
	/// 呈現、不是實況重播。要看實況得等能逐段收輸出的後端通道，那時 trace 也才有得串流。
	private func output(of result: CommandResult) -> String {
		[result.standardOutputText, result.standardErrorText]
			.filter { !$0.isEmpty }
			.joined(separator: "\n")
	}

}
