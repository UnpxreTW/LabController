//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Testing

// MARK: - JobRunnerArtifactFormatTests

/// `reports` 類兩種格式（gzip、raw）的打包腳本，以本機 bash 真的跑一次。
///
/// 與 ``JobRunnerArtifactTests`` 分開擺：那一份驗的是收集流程（分塊、失敗、上傳條件），這一份驗的是
/// 每種格式打出來的檔案長什麼樣。
private final class JobRunnerArtifactFormatTests {

	/// gzip 格式真的跑一次：每個符合的檔案各一段、依序接成一份，整份解開是各檔內容依序相接；
	/// 兩條 pattern 展開出同一條路徑時只收一次。
	@Test
	private func `packs each matching file as its own gzip member through the shell`() async throws {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("labctl-\(UUID().uuidString)")
		// 清不掉的臨時目錄只是殘留，不影響這個測試的結果，故不追究原因。
		defer { try? FileManager.default.removeItem(at: root) }
		let report: JobRunReport = await runLocally(
			[
				"mkdir -p reports",
				"printf '<a/>' > reports/a.xml",
				"printf '<b/>' > reports/b.xml",
				// gzip 檔頭記著來源檔的修改時間；不固定的話，那幾個位元組可能剛好是 1f 8b，下面數段數會多算。
				"touch -t 202601010000 reports/a.xml reports/b.xml"
			],
			declaring: .init(
				name: "junit.xml",
				paths: ["reports/*.xml", "reports/a.xml"],
				artifactType: "junit",
				artifactFormat: "gzip"
			),
			under: root
		)
		#expect(report.outcome == .completed)
		let archive: Data = try #require(report.artifacts.first?.archive)
		let archiveURL: URL = root.appendingPathComponent("retrieved.gz")
		try archive.write(to: archiveURL)
		let unpacked: CommandResult = try await LocalShellBackend().exec(
			["/usr/bin/gzip", "-dc", archiveURL.path],
			in: .init("local-1")
		)
		#expect(unpacked.standardOutputText == "<a/><b/>")
		// 一段的檔頭是 1f 8b；接成一份時第二段的檔頭緊接在第一段之後。
		let members: Int = zip(archive, archive.dropFirst()).count { $0 == 0x1F && $1 == 0x8B }
		#expect(members == 2)
	}

	/// gzip 格式只收一般檔案：符合的是目錄就打包失敗，而不是把目錄略過照樣交出去。
	@Test
	private func `fails a green job when a gzip pattern matches a directory`() async {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("labctl-\(UUID().uuidString)")
		// 清不掉的臨時目錄只是殘留，不影響這個測試的結果，故不追究原因。
		defer { try? FileManager.default.removeItem(at: root) }
		let report: JobRunReport = await runLocally(
			["mkdir -p reports/nested"],
			declaring: .init(name: "junit.xml", paths: ["reports/*"], artifactType: "junit", artifactFormat: "gzip"),
			under: root
		)
		#expect(report.outcome == .jobFailed)
		#expect(report.trace.contains("不是一般檔案"))
		#expect(report.artifacts.isEmpty)
	}

	/// raw 格式真的跑一次：唯一符合的那個檔案原樣取回；兩條 pattern 展開出同一條路徑仍算一個。
	@Test
	private func `retrieves a single raw file unchanged through the shell`() async throws {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("labctl-\(UUID().uuidString)")
		// 清不掉的臨時目錄只是殘留，不影響這個測試的結果，故不追究原因。
		defer { try? FileManager.default.removeItem(at: root) }
		let report: JobRunReport = await runLocally(
			["printf '[]' > quality.json"],
			declaring: .init(
				name: "gl-code-quality-report.json",
				paths: ["quality.json", "*.json"],
				artifactType: "codequality",
				artifactFormat: "raw"
			),
			under: root
		)
		#expect(report.outcome == .completed)
		#expect(report.artifacts.first?.archive == Data("[]".utf8))
	}

	/// raw 格式的檔案是空的就打包失敗：0 位元組與「沒有符合的檔案」在本側分不開，送出前先擋。
	@Test
	private func `fails a green job when the raw file is empty`() async {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("labctl-\(UUID().uuidString)")
		// 清不掉的臨時目錄只是殘留，不影響這個測試的結果，故不追究原因。
		defer { try? FileManager.default.removeItem(at: root) }
		let report: JobRunReport = await runLocally(
			[": > quality.json"],
			declaring: .init(
				name: "gl-code-quality-report.json",
				paths: ["quality.json"],
				artifactType: "codequality",
				artifactFormat: "raw"
			),
			under: root
		)
		#expect(report.outcome == .jobFailed)
		#expect(report.trace.contains("raw 格式的產物不收空檔"))
		#expect(report.artifacts.isEmpty)
	}

	/// raw 格式符合兩個檔案就打包失敗：站台只收一個檔案，挑其中一個送等於少收。
	@Test
	private func `fails a green job when a raw pattern matches two files`() async {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("labctl-\(UUID().uuidString)")
		// 清不掉的臨時目錄只是殘留，不影響這個測試的結果，故不追究原因。
		defer { try? FileManager.default.removeItem(at: root) }
		let report: JobRunReport = await runLocally(
			["printf a > a.json", "printf b > b.json"],
			declaring: .init(
				name: "gl-code-quality-report.json",
				paths: ["*.json"],
				artifactType: "codequality",
				artifactFormat: "raw"
			),
			under: root
		)
		#expect(report.outcome == .jobFailed)
		#expect(report.trace.contains("raw 格式的產物只能有一個"))
		#expect(report.artifacts.isEmpty)
	}

	// MARK: - 測試輔助

	/// 在 `root` 底下以本機 bash 跑一件 job：一個步驟、一項產物宣告。
	///
	/// - Parameters:
	///   - script: 步驟的命令。
	///   - declaration: 產物宣告。
	///   - root: 工作根；呼叫端負責清掉。
	/// - Returns: 這次的結果。
	private func runLocally(
		_ script: [String],
		declaring declaration: JobArtifact,
		under root: URL
	) async -> JobRunReport {
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [.init(name: "script", script: script)],
			timeoutSeconds: 600,
			artifacts: [declaration]
		)
		let runner: JobRunner = .init(
			backend: LocalShellBackend(),
			configuration: .init(workspaceRoot: root.path, shell: ["/bin/bash"])
		)
		return await runner.run(plan, on: .alias("ci-macos"))
	}
}
