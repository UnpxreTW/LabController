//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Logging

/// 把每一個自己開出去的環境登記下來、收掉之後再劃掉的一層外衣；包住任何一個 ``ExecutionBackend``。
///
/// 存在理由是**行程活不過它開出去的東西**：環境開在另一個地方（daemon 那一側），行程當掉或被
/// 重啟時它們照樣活著，而新起來的行程對它們一無所知——它們就這樣佔著併發額度，直到有人去看
/// ``ExecutionBackend/ps()``。登記簿讓重啟之後的那一輪知道「上一輪還有哪幾台沒收」。
///
/// **為什麼是一層外衣、不是寫進某個後端裡**：登記與回收跟後端是哪一種完全無關，而寫進其中一
/// 種等於下一種要再寫一次。包在外面還有一個要緊的效果——包起來之後，呼叫端能拿到的每一條開
/// 與收的路徑（含 ``ExecutionBackend/withGuest(_:do:)`` 與看門線那條直接焚毀）都會經過這裡，
/// 沒有哪一條繞得過去。
///
/// - Important: 回收**只收登記在案的**。同一台機器上開環境的不只 lab-controller 一個，照
///   ``ExecutionBackend/ps()`` 收掉等於把別人正在用的一起焚毀。
public struct RegisteringExecutionBackend: ExecutionBackend {

	// MARK: Public

	/// 一次回收的結果。
	public struct Reclamation: Sendable, Equatable {

		/// 收掉了哪幾台。
		public let reclaimed: [GuestIdentifier]

		/// 哪幾台沒收成；它們留在登記簿上，下一次啟動再試。
		public let failed: [GuestIdentifier]

		/// 登記簿讀不開；這一次一台都不收。
		public let registryUnreadable: Bool

		/// 逐欄建立。
		public init(
			reclaimed: [GuestIdentifier] = [],
			failed: [GuestIdentifier] = [],
			registryUnreadable: Bool = false
		) {
			self.reclaimed = reclaimed
			self.failed = failed
			self.registryUnreadable = registryUnreadable
		}
	}

	/// 兩輪回收之間預設隔多久。
	///
	/// 對齊的是「服務管理器把後端也拉起來」要花的時間，量級是秒。
	public static let defaultRetryInterval: Duration = .seconds(10)

	/// 把上一輪留下來、登記在案的環境全部收掉。
	///
	/// - Warning: 啟動時呼叫，而且只在啟動時。這一刻手上一件 job 都還沒領，所以「登記在案」與
	///   「沒有對應的工作」是同一件事——不必另外記一份在飛的工作清單，也就沒有那份清單與現實
	///   對不上的可能。行程跑起來之後不要再呼叫它：那時登記在案的正是當下在跑的那一台。
	///
	/// **一台收不掉不影響其餘**：收不掉的留在登記簿上；就此把它劃掉等於再也沒有人會回來收它。
	///
	/// **收不掉的那些會再試幾輪**：啟動這一刻最常見的失敗原因是後端自己也還沒起來——機器重開
	/// 時兩邊被同時拉起，先到的那個一問就是「連不上」。只試一次的話，上一輪留下的環境會一路
	/// 佔到下一次重啟為止，而那正是這一片要治的事。重試只針對第一輪沒收成的那幾個識別碼、
	/// 不重讀登記簿，因此不會碰到本行程剛開起來的環境。
	///
	/// - Parameters:
	///   - attempts: 最多試幾輪；預設 1（只試一次）。
	///   - waitBeforeRetry: 兩輪之間的等待；測試注入不真的睡的版本。
	///   - retryInterval: 兩輪之間隔多久。
	/// - Returns: 這一次收了哪些、哪些沒收成。
	public func reclaimOrphans(
		attempts: Int = 1,
		// `try?` 吞掉的只有取消：等待被中斷＝不必再等，下一輪自己會看清單還剩什麼。
		waitBeforeRetry: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
		retryInterval: Duration = Self.defaultRetryInterval
	) async -> Reclamation {
		let entries: [GuestRegistry.Entry]
		do {
			entries = try await registry.entries()
		} catch {
			// 只警示、不收：讀不開的登記簿說不出「是哪幾台」，而唯一的替代來源（後端列出來的
			// 全部環境）裡有別人的。先把它改名留存，下一次登記才不會把這份線索蓋掉。
			logger.warning("guest registry unreadable, skipping reclaim: \(error)")
			do {
				if let kept: URL = try await registry.quarantine(at: Date()) {
					logger.warning("unreadable guest registry kept at \(kept.path)")
				}
			} catch {
				logger.warning("unreadable guest registry could not be set aside: \(error)")
			}
			return .init(registryUnreadable: true)
		}
		var reclaimed: [GuestIdentifier] = []
		var pending: [GuestIdentifier] = entries.map(\.guest)
		// 這份清單在進迴圈時就定下來、之後不再回頭讀登記簿：重讀等於把本行程剛開起來、正在跑
		// 的那一台也讀進來，而它不是殘骸。
		for attempt: Int in 0 ..< max(1, attempts) where !pending.isEmpty {
			if attempt > 0 { await waitBeforeRetry(retryInterval) }
			var stillPending: [GuestIdentifier] = []
			for guest: GuestIdentifier in pending {
				do {
					try await backend.destroy(guest)
				} catch {
					stillPending.append(guest)
					logger.warning("orphan guest \(guest) could not be destroyed: \(error)")
					continue
				}
				reclaimed.append(guest)
				logger.info("reclaimed orphan guest \(guest)")
				await forget(guest, after: "reclaim")
			}
			pending = stillPending
		}
		return .init(reclaimed: reclaimed, failed: pending)
	}

	/// 開一個環境，開成了就登記下來。
	///
	/// **登記寫不進去時把剛開好的那台收掉**：登記簿是回收的唯一依據，沒登記的那一台就是沒有人
	/// 收得到的孤兒——而這正是這一層要防的事。寧可這一件 job 當場以環境層失敗收場（站台端會另
	/// 派一台重跑），也不要留下一個看不見的佔用。
	///
	/// - Parameter specification: 環境規格。
	/// - Returns: 新環境的識別碼。
	/// - Throws: ``ExecutionBackendError``。
	public func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
		let guest: GuestIdentifier = try await backend.spawn(specification)
		do {
			try await registry.record(guest)
		} catch {
			// 路徑與底層原文只進本機紀錄：往上拋的那一則會被寫進交回站台的 trace。
			logger.error("guest \(guest) could not be registered: \(error)")
			do {
				try await backend.destroy(guest)
			} catch {
				// 登記不成、連收都收不掉 ⇒ 留下一台不在案上的環境，往後任何一輪回收都看不到它。
				// 這一行是它唯一的線索。
				logger.error("guest \(guest) is now an orphan: it could neither be registered nor destroyed")
			}
			throw ExecutionBackendError.backendUnavailable(detail: "執行環境登記不下來")
		}
		return guest
	}

	/// 原樣轉給底下那一層。
	public func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
		try await backend.exec(command, in: guest)
	}

	/// 原樣轉給底下那一層。
	public func ps() async throws -> [GuestSummary] {
		try await backend.ps()
	}

	/// 原樣轉給底下那一層。
	public func status(of guest: GuestIdentifier) async throws -> GuestSummary {
		try await backend.status(of: guest)
	}

	/// 收掉一個環境，收成了才自登記簿劃掉。
	///
	/// **收不成就不劃掉**：那台多半還在，而劃掉之後就再也沒有人會回來收它。留著的代價只是下一
	/// 次啟動多送一次焚毀，而焚毀是冪等的。
	///
	/// - Parameter guest: 環境識別碼。
	/// - Throws: ``ExecutionBackendError``。
	public func destroy(_ guest: GuestIdentifier) async throws {
		try await backend.destroy(guest)
		await forget(guest, after: "destroy")
	}

	/// 包住一個後端。
	///
	/// - Parameters:
	///   - backend: 真正在開環境的那一個。
	///   - registry: 登記簿。
	///   - logger: 紀錄出口；這一層只送出紀錄、不決定它們寫去哪裡。
	public init(
		wrapping backend: any ExecutionBackend,
		registry: GuestRegistry,
		logger: Logger = .init(label: "lab-controller")
	) {
		self.backend = backend
		self.registry = registry
		self.logger = logger
	}

	// MARK: Private

	/// 真正在開環境的那一個。
	private let backend: any ExecutionBackend

	/// 登記簿。
	private let registry: GuestRegistry

	/// 這一層的紀錄出口。
	private let logger: Logger

	/// 自登記簿劃掉；寫不進去只警示。
	///
	/// **劃不掉不往上拋**：到這裡的時候環境已經收乾淨了，把一件做完的事回報成失敗，呼叫端會去
	/// 做一次不必要的收拾。留在登記簿上的那一筆只會讓下一次啟動多送一次冪等的焚毀。
	///
	/// - Parameters:
	///   - guest: 環境識別碼。
	///   - context: 這一次是在哪條路徑上劃的；只進紀錄。
	private func forget(_ guest: GuestIdentifier, after context: String) async {
		do {
			try await registry.forget(guest)
		} catch {
			logger.warning("guest \(guest) stayed in the registry after \(context): \(error)")
		}
	}
}
