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

/// 把注入檔真的寫到本機、把命令真的交給本機行程跑的後端。
///
/// 存在理由是**腳本本身**：記在記憶體裡的後端只驗得到本側送出哪幾道命令，驗不到送進去的 shell
/// 腳本在真的 bash、`zip`、`dd`、`base64` 底下是否拼得回一份檔案。注入檔的路徑是絕對路徑，故
/// 呼叫端要把工作根設在一個臨時目錄底下，寫入的位置才不會落在臨時目錄之外。
internal final class LocalShellBackend: ExecutionBackend {

	/// 把注入檔逐份寫到本機，權限照注入檔所記。
	internal func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
		for file in specification.injectedFiles {
			let url: URL = .init(fileURLWithPath: file.path)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			try file.contents.write(to: url)
			try FileManager.default.setAttributes([.posixPermissions: Int(file.permissions)], ofItemAtPath: file.path)
		}
		let identifier: GuestIdentifier = .init("local-1")
		guests.withLock {
			$0 = [.init(identifier: identifier, image: specification.image, state: .running, startedAt: .init())]
		}
		return identifier
	}

	/// 以命令的第一個參數為可執行檔、其餘為參數跑一次，收兩道輸出。
	internal func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
		let process: Process = .init()
		process.executableURL = .init(fileURLWithPath: command[0])
		process.arguments = Array(command.dropFirst())
		let standardOutput: Pipe = .init()
		let standardError: Pipe = .init()
		process.standardOutput = standardOutput
		process.standardError = standardError
		try process.run()
		// 兩道輸出並行讀完再等：任一道塞滿管線時，行程會停在寫入那一步、永遠等不到它結束。
		let errorReader: FileHandle = standardError.fileHandleForReading
		let errorReading: Task<Data, Never> = .detached { errorReader.readDataToEndOfFile() }
		let output: Data = standardOutput.fileHandleForReading.readDataToEndOfFile()
		let error: Data = await errorReading.value
		process.waitUntilExit()
		return .init(command: command, exitCode: process.terminationStatus, standardOutput: output, standardError: error)
	}

	/// 還在的環境。
	internal func ps() async throws -> [GuestSummary] {
		guests.withLock { $0 }
	}

	/// 查單一環境；查無即拋。
	internal func status(of guest: GuestIdentifier) async throws -> GuestSummary {
		guard let summary: GuestSummary = guests.withLock({ $0.first { $0.identifier == guest } }) else {
			throw ExecutionBackendError.unknownGuest(guest)
		}
		return summary
	}

	/// 只把環境從清單上拿掉；臨時目錄由呼叫端收拾。
	internal func destroy(_ guest: GuestIdentifier) async throws {
		guests.withLock { $0.removeAll { $0.identifier == guest } }
	}

	/// 開過的環境；只有一個欄位，上鎖即可。
	private let guests: Mutex<[GuestSummary]> = .init([])
}
