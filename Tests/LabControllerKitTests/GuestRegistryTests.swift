//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Logging
import Synchronization
import Testing

// MARK: - GuestRegistryTests

private final class GuestRegistryTests {

	/// 本次測試的暫存目錄；每個實例一個，測試之間不共用檔案。
	private let directory: URL

	/// 建暫存目錄。
	internal init() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("GuestRegistryTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	/// 收掉暫存目錄；清不掉也不讓測試失敗（清理失敗不是被測行為）。
	deinit {
		// `try?`：清不掉也不讓測試失敗——清理不是被測行為。
		try? FileManager.default.removeItem(at: directory)
	}

	/// 預設位置就是 README 與說明上寫的那一個；路徑字面在這裡釘住。
	@Test
	private func `puts the default registry under the home directory`() {
		#expect(
			GuestRegistry.defaultURL(homeDirectory: URL(fileURLWithPath: "/home/someone")).path
				== "/home/someone/.lab-controller/sessions.json"
		)
	}

	/// 執行期才壞掉的那一份也要先留存再覆寫——啟動時的那次警示碰不到它。
	@Test
	private func `sets an unreadable registry aside before recording over it`() async throws {
		let url: URL = try corruptedRegistry()
		let registry: GuestRegistry = .init(at: url, now: { Self.spawnedAt })
		try await registry.record(.init("guest-1"))
		#expect(try await registry.entries().map(\.guest) == [.init("guest-1")])
		let kept: [String] = try FileManager.default
			.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
			.filter { $0.contains("corrupt-") }
		#expect(kept.count == 1)
	}

	/// 登記簿還沒有檔案時查回空的——第一次跑是正常路徑、不是錯誤。
	@Test
	private func `reports nothing registered before the file exists`() async throws {
		let registry: GuestRegistry = .init(at: registryURL())
		#expect(try await registry.entries().isEmpty)
	}

	/// 記下的環境讀得回來，劃掉之後就不在了。
	@Test
	private func `records and forgets guests`() async throws {
		let registry: GuestRegistry = .init(at: registryURL(), now: { Self.spawnedAt })
		try await registry.record(.init("guest-1"))
		try await registry.record(.init("guest-2"))
		#expect(try await registry.entries() == [
			.init(guest: .init("guest-1"), spawnedAt: Self.spawnedAt),
			.init(guest: .init("guest-2"), spawnedAt: Self.spawnedAt)
		])
		try await registry.forget(.init("guest-1"))
		#expect(try await registry.entries().map(\.guest) == [.init("guest-2")])
		// 不在案上的也算劃掉成功：收拾路徑常被走兩次，第二次要的正是「已經沒有了」。
		try await registry.forget(.init("guest-1"))
		#expect(try await registry.entries().count == 1)
	}

	/// 另一個行程讀得到前一個行程寫下的內容——這正是重啟之後回收所依賴的事。
	@Test
	private func `survives a new registry instance on the same file`() async throws {
		let url: URL = registryURL()
		try await GuestRegistry(at: url, now: { Self.spawnedAt }).record(.init("guest-1"))
		#expect(try await GuestRegistry(at: url).entries().map(\.guest) == [.init("guest-1")])
	}

	/// 內容壞掉時拋、不收斂成空集合：讀不開代表「可能有東西要收、但不知道是哪些」。
	@Test
	private func `throws when the file cannot be decoded`() async throws {
		let url: URL = try corruptedRegistry()
		await #expect(throws: GuestRegistryError.self) {
			try await GuestRegistry(at: url).entries()
		}
	}

	/// 壞掉的舊內容不擋住往後的登記：連寫都不讓寫的話，一份壞檔會讓每一次開環境都失敗。
	@Test
	private func `overwrites an unreadable file on the next record`() async throws {
		let url: URL = try corruptedRegistry()
		let registry: GuestRegistry = .init(at: url, now: { Self.spawnedAt })
		try await registry.record(.init("guest-1"))
		#expect(try await registry.entries().map(\.guest) == [.init("guest-1")])
	}

	/// 登記時刻的固定值；測試不取系統時鐘。
	private static let spawnedAt: Date = .init(timeIntervalSince1970: 1_800_000_000)

	/// 第二個行程拿不到同一份登記簿的鎖——共用會讓後起來的那個去收前一個正在跑的環境。
	@Test
	private func `refuses the lock while another holder has it`() async throws {
		let url: URL = registryURL()
		let holder: GuestRegistry = .init(at: url)
		try await holder.acquireExclusiveLock()
		// 同一份登記簿再取一次就該被擋下；已經拿到的那一份再取是沒事的。
		try await holder.acquireExclusiveLock()
		await #expect(throws: GuestRegistryError.lockHeld(path: url.appendingPathExtension("lock").path)) {
			try await GuestRegistry(at: url).acquireExclusiveLock()
		}
		// 登記一筆再問一次：寫入是整份換新檔，鎖若打在登記簿本身，這一刻起就會留在被換掉的
		// 那個舊檔上、而第二個行程照樣取得到鎖——那正是這一片要防的事故，只是晚一步發生。
		try await holder.record(.init("guest-1"))
		await #expect(throws: GuestRegistryError.lockHeld(path: url.appendingPathExtension("lock").path)) {
			try await GuestRegistry(at: url).acquireExclusiveLock()
		}
	}

	/// 壞掉的那一份改名留存，不是被下一次登記直接蓋掉——它是孤兒識別碼的唯一線索。
	@Test
	private func `sets an unreadable registry aside`() async throws {
		let url: URL = try corruptedRegistry()
		let registry: GuestRegistry = .init(at: url, now: { Self.spawnedAt })
		let kept: URL? = try await registry.quarantine(at: Self.spawnedAt)
		#expect(kept != nil)
		#expect(FileManager.default.fileExists(atPath: url.path) == false)
		let keptText: String = try String(contentsOf: try #require(kept), encoding: .utf8)
		#expect(keptText == "這不是 JSON")
	}

	/// 一個還不存在的登記簿檔案位置。
	private func registryURL() -> URL {
		directory
			.appending(component: ".lab-controller", directoryHint: .isDirectory)
			.appending(component: "sessions.json", directoryHint: .notDirectory)
	}

	/// 一份內容壞掉的登記簿；上層目錄一併建好。
	private func corruptedRegistry() throws -> URL {
		let url: URL = registryURL()
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try Data("這不是 JSON".utf8).write(to: url)
		return url
	}
}

// MARK: - RegisteringExecutionBackendTests

private final class RegisteringExecutionBackendTests {

	/// 本次測試的暫存目錄。
	private let directory: URL

	/// 建暫存目錄。
	internal init() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RegisteringBackendTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	/// 收掉暫存目錄。
	deinit {
		// `try?`：清不掉也不讓測試失敗——清理不是被測行為。
		try? FileManager.default.removeItem(at: directory)
	}

	/// 一件工作正常收尾之後登記簿是空的——開一台、記一筆、收掉、劃掉。
	@Test
	private func `leaves the registry empty after a guest is destroyed`() async throws {
		let registry: GuestRegistry = .init(at: registryURL())
		let inner: InMemoryExecutionBackend = .init()
		let backend: RegisteringExecutionBackend = .init(wrapping: inner, registry: registry)
		try await backend.withGuest(.init(image: .alias("ci-linux"))) { guest in
			// 環境還在跑的期間登記得在案上，否則行程這時當掉就沒有人收得到它。
			let registered: [GuestIdentifier] = try await registry.entries().map(\.guest)
			#expect(registered == [guest])
		}
		#expect(try await registry.entries().isEmpty)
		#expect(inner.destroyCount == 1)
	}

	/// 重啟之後只收登記在案的那些；同一台機器上別人開的環境一台都不能動。
	@Test
	private func `reclaims only the guests it registered`() async throws {
		let url: URL = registryURL()
		let inner: InMemoryExecutionBackend = .init()
		// 別人開的那一台：直接對底層後端開，沒有經過登記那一層。
		let foreign: GuestIdentifier = try await inner.spawn(.init(image: .alias("ci-linux")))
		// 我們開的那一台：開了就沒再收——行程在這裡當掉。
		let owned: GuestIdentifier = try await RegisteringExecutionBackend(
			wrapping: inner,
			registry: .init(at: url)
		).spawn(.init(image: .alias("ci-linux")))
		// 重啟：新的行程拿同一份登記簿、同一個後端。
		let restarted: RegisteringExecutionBackend = .init(wrapping: inner, registry: .init(at: url))
		let reclamation: RegisteringExecutionBackend.Reclamation = await restarted.reclaimOrphans()
		#expect(reclamation.reclaimed == [owned])
		#expect(reclamation.failed.isEmpty)
		#expect(reclamation.registryUnreadable == false)
		#expect(try await inner.ps().map(\.identifier) == [foreign])
		// 收完就劃掉：留著會讓下一次啟動再送一次沒有意義的焚毀。
		#expect(try await GuestRegistry(at: url).entries().isEmpty)
	}

	/// 登記簿讀不開時一台都不收，只留一行警示。
	@Test
	private func `reclaims nothing when the registry cannot be read`() async throws {
		let url: URL = registryURL()
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try Data("這不是 JSON".utf8).write(to: url)
		let inner: InMemoryExecutionBackend = .init()
		_ = try await inner.spawn(.init(image: .alias("ci-linux")))
		let lines: Mutex<[String]> = .init([])
		let backend: RegisteringExecutionBackend = .init(
			wrapping: inner,
			registry: .init(at: url),
			logger: CapturingLogHandler.logger { level, message in
				lines.withLock { $0.append("\(level) \(message)") }
			}
		)
		let reclamation: RegisteringExecutionBackend.Reclamation = await backend.reclaimOrphans()
		#expect(reclamation.registryUnreadable)
		#expect(reclamation.reclaimed.isEmpty)
		#expect(inner.destroyCount == 0)
		#expect(lines.withLock { $0.contains { $0.contains("warning") && $0.contains("registry unreadable") } })
	}

	/// 焚毀失敗的那一台留在登記簿上，下一次啟動再試；就此劃掉等於再也沒有人會回來收它。
	@Test
	private func `keeps an entry whose guest could not be destroyed`() async throws {
		let url: URL = registryURL()
		let registry: GuestRegistry = .init(at: url)
		try await registry.record(.init("guest-9"))
		let inner: InMemoryExecutionBackend = .init(
			script: .init(destroyError: .backendUnavailable(detail: "socket closed"))
		)
		let backend: RegisteringExecutionBackend = .init(wrapping: inner, registry: registry)
		let reclamation: RegisteringExecutionBackend.Reclamation = await backend.reclaimOrphans()
		#expect(reclamation.reclaimed.isEmpty)
		#expect(reclamation.failed == [.init("guest-9")])
		#expect(try await registry.entries().map(\.guest) == [.init("guest-9")])
	}

	/// 登記寫不進去時，剛開好的那台當場被收掉：沒登記的環境沒有人收得到，正是這一層要防的事。
	@Test
	private func `destroys a guest it cannot register`() async throws {
		// 上層目錄的位置被一個普通檔案佔著 ⇒ 建目錄必定失敗 ⇒ 登記寫不進去。
		let blocker: URL = directory.appending(component: "blocked", directoryHint: .notDirectory)
		try Data().write(to: blocker)
		let inner: InMemoryExecutionBackend = .init()
		let backend: RegisteringExecutionBackend = .init(
			wrapping: inner,
			registry: .init(at: blocker.appending(component: "sessions.json", directoryHint: .notDirectory))
		)
		await #expect(throws: ExecutionBackendError.self) {
			try await backend.spawn(.init(image: .alias("ci-linux")))
		}
		#expect(inner.destroyCount == 1)
		#expect(try await inner.ps().isEmpty)
	}

	/// 第一輪連不上的那些會再試——機器重開時後端自己也還沒起來，只試一輪等於放著不收。
	@Test
	private func `retries the guests it could not destroy`() async throws {
		let url: URL = registryURL()
		let registry: GuestRegistry = .init(at: url)
		try await registry.record(.init("guest-9"))
		// 前兩輪一律連不上，第三輪才收得掉。
		let inner: FlakyDestroyBackend = .init(failuresBeforeSuccess: 2)
		let backend: RegisteringExecutionBackend = .init(wrapping: inner, registry: registry)
		// 兩輪之間登記一台「本行程剛開起來、正在跑」的環境：重試若回頭重讀登記簿，就會把它
		// 一起收掉——而那是一件正在跑的 job 的環境，不是上一輪的殘骸。
		let reclamation: RegisteringExecutionBackend.Reclamation = await backend.reclaimOrphans(
			attempts: 3,
			// `try?`：等待閉包不能拋，登記寫不進去時下方的斷言會紅——不必在這裡再處理一次。
			waitBeforeRetry: { _ in try? await registry.record(.init("live")) },
			retryInterval: .zero
		)
		#expect(reclamation.reclaimed == [.init("guest-9")])
		#expect(reclamation.failed.isEmpty)
		#expect(inner.destroyAttempts == 3)
		#expect(inner.destroyedGuests.contains(.init("live")) == false)
		#expect(try await registry.entries().map(\.guest) == [.init("live")])
	}

	/// 讀不開時把那一份改名留存：下一次登記會整份覆寫，而它是孤兒識別碼的唯一線索。
	@Test
	private func `keeps an unreadable registry aside before moving on`() async throws {
		let url: URL = registryURL()
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try Data("這不是 JSON".utf8).write(to: url)
		let backend: RegisteringExecutionBackend = .init(
			wrapping: InMemoryExecutionBackend(),
			registry: .init(at: url)
		)
		#expect(await backend.reclaimOrphans().registryUnreadable)
		#expect(FileManager.default.fileExists(atPath: url.path) == false)
		let kept: [String] = try FileManager.default
			.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
			.filter { $0.contains("corrupt-") }
		#expect(kept.count == 1)
	}

	/// 一個還不存在的登記簿檔案位置。
	private func registryURL() -> URL {
		directory
			.appending(component: ".lab-controller", directoryHint: .isDirectory)
			.appending(component: "sessions.json", directoryHint: .notDirectory)
	}
}

// MARK: - FlakyDestroyBackend

/// 前幾次焚毀一律連不上、之後才收得掉的後端；用來驗回收那幾輪重試。
private final class FlakyDestroyBackend: ExecutionBackend {

	/// 送過幾次焚毀。
	internal var destroyAttempts: Int {
		attempts.withLock { $0.count }
	}

	/// 被送過焚毀的那些識別碼，依送出順序。
	internal var destroyedGuests: [GuestIdentifier] {
		attempts.withLock { $0 }
	}

	/// 以「前幾次一律失敗」建立。
	internal init(failuresBeforeSuccess: Int) {
		self.failuresBeforeSuccess = failuresBeforeSuccess
	}

	/// 這個後端不開環境。
	internal func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
		throw ExecutionBackendError.backendUnavailable(detail: "socket closed")
	}

	/// 這個後端不跑命令。
	internal func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
		throw ExecutionBackendError.backendUnavailable(detail: "socket closed")
	}

	/// 沒有環境可列。
	internal func ps() async throws -> [GuestSummary] {
		[]
	}

	/// 一律查無。
	internal func status(of guest: GuestIdentifier) async throws -> GuestSummary {
		throw ExecutionBackendError.unknownGuest(guest)
	}

	/// 前幾次拋「連不上」，之後成功。
	internal func destroy(_ guest: GuestIdentifier) async throws {
		let attempt: Int = attempts.withLock { sent in
			sent.append(guest)
			return sent.count
		}
		guard attempt > failuresBeforeSuccess else {
			throw ExecutionBackendError.backendUnavailable(detail: "socket closed")
		}
	}

	/// 前幾次要失敗。
	private let failuresBeforeSuccess: Int

	/// 送過焚毀的那些識別碼。
	private let attempts: Mutex<[GuestIdentifier]> = .init([])
}
