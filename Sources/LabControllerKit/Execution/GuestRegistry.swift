//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 記住「這個行程開了哪些執行環境、還沒收掉」的持久層。
///
/// 行程被收掉（當掉、被服務管理器重啟、機器重開）時，它開出去的環境不會跟著消失——它們留在
/// 後端那裡佔著併發額度，而新起來的行程對它們一無所知。``ExecutionBackend/ps()`` 看得到全部
/// 環境，但那裡面也有別人開的（同一台機器上不只一個東西在開環境），照單收掉會把別人正在用的
/// 一起焚毀。
///
/// - Important: **這份登記簿是回收的唯一依據**：只有登記在案的才收得掉，沒登記的一律不動。
///   代價是登記寫不進去的那一台會變成收不到的孤兒——所以寫不進去時開環境那一側直接把它收掉、
///   不讓它活下來（見 ``RegisteringExecutionBackend/spawn(_:)``）。
///
/// - Warning: 一份登記簿只給一個行程用。讀改寫三步之間沒有跨行程的交易，兩個行程共用同一份
///   時，新起來的那個會把另一個正在跑的環境當成上一輪的殘骸收掉。這件事不靠約定擋——行程啟動
///   時以 ``acquireExclusiveLock()`` 取一把獨佔鎖，取不到就當場停下來，而不是安靜地去收別人的
///   環境。同一台機器要跑兩份時各自給一份登記簿（`run --registry`）。
///
/// **檔案格式刻意做成人讀得懂的 JSON**：這份東西會在「出事之後」被人打開來看——哪一台掛著、
/// 掛了多久，而那個時刻通常沒有工具可用。
public actor GuestRegistry {

	// MARK: Public

	/// 登記簿上的一筆。
	public struct Entry: Sendable, Equatable {

		/// 環境識別碼。
		public let guest: GuestIdentifier

		/// 登記的時刻，即這個環境開起來的時刻。
		///
		/// 回收時只寫進紀錄、不參與判斷：判斷「該不該收」的是「有沒有登記在案」，拿時間當門檻
		/// 等於替那些開很久的正常工作設一個沒人同意過的上限。
		public let spawnedAt: Date

		/// 逐欄建立。
		public init(guest: GuestIdentifier, spawnedAt: Date) {
			self.guest = guest
			self.spawnedAt = spawnedAt
		}
	}

	/// 預設的登記簿位置：家目錄下的 `.lab-controller/sessions.json`。
	///
	/// - Parameter homeDirectory: 家目錄；測試指到暫存目錄。
	/// - Returns: 登記簿檔案的絕對位置。
	public static func defaultURL(
		homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
	) -> URL {
		homeDirectory
			.appending(component: ".lab-controller", directoryHint: .isDirectory)
			.appending(component: "sessions.json", directoryHint: .notDirectory)
	}

	/// 取這份登記簿的獨佔鎖；取不到即表示另一個行程正用著它。
	///
	/// **在回收之前取、而且整個行程期間不放**：回收會對登記在案的每一台送焚毀，而「登記在案」
	/// 只有在這份登記簿專屬於本行程時才等於「上一輪留下來的」。鎖打在一個並排的 `.lock` 檔上，
	/// 而不是登記簿本身——登記簿每次都是整份換新檔（見 ``save(_:)``），鎖在被換掉的那個 inode
	/// 上等於沒鎖。
	///
	/// - Important: 取鎖證明的只是「鎖檔開得起來」。上層目錄既存時 `createDirectory` 直接算
	///   成功，而鎖檔一旦建過就開得起來——目錄之後被改成不可寫，這裡仍然會過。真正的寫入失敗
	///   要等 ``record(_:)`` 那一刻才看得到。
	///
	/// - Throws: ``GuestRegistryError/lockHeld(path:)``（另一個行程佔著）或
	///   ``GuestRegistryError/notWritable(path:detail:)``（目錄或檔案根本開不起來）。
	public func acquireExclusiveLock() throws {
		guard lockDescriptor == nil else { return }
		let lockURL: URL = url.appendingPathExtension("lock")
		do {
			try FileManager.default.createDirectory(
				at: url.deletingLastPathComponent(),
				withIntermediateDirectories: true,
				attributes: [.posixPermissions: 0o700]
			)
		} catch {
			throw GuestRegistryError.notWritable(path: lockURL.path, detail: "\(error)")
		}
		// `O_NOFOLLOW`：登記簿位置可由 `--registry` 指定，指到共用目錄時，別人先擺一個 symlink
		// 就能把鎖引到別處去。跟著走的那一次不會報錯，只會讓獨佔悄悄失效。
		let descriptor: Int32 = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else {
			throw GuestRegistryError.notWritable(path: lockURL.path, detail: "open errno \(errno)")
		}
		guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
			let code: Int32 = errno
			close(descriptor)
			guard code == EWOULDBLOCK else {
				throw GuestRegistryError.notWritable(path: lockURL.path, detail: "flock errno \(code)")
			}
			throw GuestRegistryError.lockHeld(path: lockURL.path)
		}
		// 不關：鎖跟著這個檔案描述符，關掉就放掉了。行程結束時由系統收回。
		lockDescriptor = descriptor
	}

	/// 把一份讀不開的登記簿改名留存，讓往後的登記從乾淨狀態開始。
	///
	/// **留存而不是直接覆寫**：讀不開的那一份是「可能有孤兒、但不知道是哪些」的唯一線索，而
	/// 下一次 ``record(_:)`` 會把它整份蓋掉——出事之後想打開來看的那個人，看到的會是一份只有
	/// 新環境的檔案。改名之後兩件事都保得住。
	///
	/// - Returns: 留存後的位置；本來就沒有檔案時為 nil。
	/// - Throws: ``GuestRegistryError/notWritable(path:detail:)``。
	@discardableResult
	public func quarantine(at instant: Date) throws -> URL? {
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		// 冒號換成減號：`:` 在某些檔案系統與工具鏈上是路徑分隔符，留著會讓這份留存檔變得難取用。
		let stamp: String = instant
			.formatted(.iso8601.dateTimeSeparator(.standard))
			.replacingOccurrences(of: ":", with: "-")
		let kept: URL = url.appendingPathExtension("corrupt-\(stamp)")
		do {
			try FileManager.default.moveItem(at: url, to: kept)
		} catch {
			throw GuestRegistryError.notWritable(path: url.path, detail: "\(error)")
		}
		return kept
	}

	/// 登記一個剛開起來的環境。
	///
	/// **讀不開的舊內容先留存、再當成空的往下寫**：登記簿壞掉時若連寫都不讓寫，每一次開環境
	/// 都會失敗，等於一份壞掉的紀錄把整個行程停掉；而直接覆寫會把「壞掉之前登記了哪幾台」這
	/// 條唯一的線索一起抹掉——執行期才壞掉的那一次沒有人會在啟動時警示它。留存失敗也照樣往下
	/// 走：這條路徑上真正要保住的是「開出去的環境記得住」。
	///
	/// - Parameter guest: 環境識別碼。
	/// - Throws: ``GuestRegistryError/notWritable(path:detail:)``。
	public func record(_ guest: GuestIdentifier) throws {
		var entries: [Entry] = []
		do {
			entries = try load()
		} catch {
			try? quarantine(at: now())
		}
		entries.removeAll { $0.guest == guest }
		entries.append(.init(guest: guest, spawnedAt: now()))
		try save(entries)
	}

	/// 把一個已經收掉的環境自登記簿劃掉；不在案上也算成功。
	///
	/// 「不在案上」是正常路徑：收拾路徑常被走兩次，而第二次要的正是「已經沒有了」——與
	/// ``ExecutionBackend/destroy(_:)`` 的冪等要求同一個理由。
	///
	/// - Parameter guest: 環境識別碼。
	/// - Throws: ``GuestRegistryError/notWritable(path:detail:)``。
	public func forget(_ guest: GuestIdentifier) throws {
		// `try?`：讀不開時沒有東西可劃掉，而失敗的原因這裡用不上——留存與警示走 `record(_:)`
		// 與回收那兩條路徑，在這裡再做一次只會把同一份壞檔改名兩次。
		let entries: [Entry] = (try? load()) ?? []
		let remaining: [Entry] = entries.filter { $0.guest != guest }
		guard remaining.count != entries.count else { return }
		try save(remaining)
	}

	/// 當下登記在案的全部環境，依登記順序。
	///
	/// **檔案不在回空、內容壞掉才拋**：沒有檔案是正常路徑（第一次跑、或上一次乾淨收工），而
	/// 壞掉的內容代表「本來可能有東西要收、但現在不知道是哪些」——把它收斂成空集合，就是把一次
	/// 該被看見的異常變成一次安靜的「沒事」。
	///
	/// - Returns: 登記在案的環境。
	/// - Throws: ``GuestRegistryError/unreadable(path:detail:)``。
	public func entries() throws -> [Entry] {
		try load()
	}

	/// 開一份登記簿；檔案與其上層目錄都等到第一次寫入時才建。
	///
	/// - Parameters:
	///   - url: 登記簿檔案位置。
	///   - now: 取當下時刻；測試注入固定時鐘。
	public init(at url: URL, now: @escaping @Sendable () -> Date = Date.init) {
		self.url = url
		self.now = now
	}

	// MARK: Private

	/// 這份檔案的格式版本；日後改格式時，舊檔要不要讀得動由它決定。
	private static let currentVersion: Int = 1

	/// 落地時的樣子；外面那層 ``Entry`` 帶的是 ``GuestIdentifier``，而它刻意不對格式做承諾、
	/// 因此不自帶編解碼——線上與記憶體裡的形狀在這裡分開。
	private struct Document: Codable {

		/// 格式版本。
		internal let version: Int

		/// 登記在案的環境。
		internal let guests: [Record]
	}

	/// 落地時的一筆。
	private struct Record: Codable {

		/// 環境識別碼的原字串。
		internal let identifier: String

		/// 登記時刻。
		internal let spawnedAt: Date
	}

	/// 登記簿檔案位置。
	private let url: URL

	/// 取當下時刻。
	private let now: @Sendable () -> Date

	/// 獨佔鎖的檔案描述符；還沒取鎖時為 nil。
	///
	/// 刻意不在任何地方關掉它：鎖的壽命就是這個行程的壽命，提早關等於在還開著環境的時候把
	/// 登記簿讓給別人。
	private var lockDescriptor: Int32?

	/// 讀出當下的內容；檔案不在回空。
	private func load() throws -> [Entry] {
		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return []
		} catch {
			throw GuestRegistryError.unreadable(path: url.path, detail: "\(error)")
		}
		let decoder: JSONDecoder = .init()
		decoder.dateDecodingStrategy = .iso8601
		let document: Document
		do {
			document = try decoder.decode(Document.self, from: data)
		} catch {
			throw GuestRegistryError.unreadable(path: url.path, detail: "\(error)")
		}
		guard document.version == Self.currentVersion else {
			throw GuestRegistryError.unreadable(
				path: url.path,
				detail: "格式版本 \(document.version) 不是這一版認得的 \(Self.currentVersion)"
			)
		}
		return document.guests.map { .init(guest: .init($0.identifier), spawnedAt: $0.spawnedAt) }
	}

	/// 整份寫回去。
	///
	/// **先寫到旁邊再換過去**（`Data.WritingOptions.atomic`）：寫到一半斷電時，原地覆寫留下的是
	/// 一份截斷的檔——而那正是最需要它完整的時候。權限每次都重設一次，因為那個手法留下的是一份
	/// 新檔、不是原來那一份。
	private func save(_ entries: [Entry]) throws {
		let document: Document = .init(
			version: Self.currentVersion,
			guests: entries.map { .init(identifier: $0.guest.rawValue, spawnedAt: $0.spawnedAt) }
		)
		let encoder: JSONEncoder = .init()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		do {
			let directory: URL = url.deletingLastPathComponent()
			// 上層目錄由這裡建：登記簿是本型別自己的東西，交給佈署去建等於多一個沒建就靜靜不
			// 生效的前置條件，而不生效的樣子就是「孤兒照樣沒人收」。
			try FileManager.default.createDirectory(
				at: directory,
				withIntermediateDirectories: true,
				attributes: [.posixPermissions: 0o700]
			)
			try encoder.encode(document).write(to: url, options: .atomic)
			try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
		} catch {
			throw GuestRegistryError.notWritable(path: url.path, detail: "\(error)")
		}
	}
}
