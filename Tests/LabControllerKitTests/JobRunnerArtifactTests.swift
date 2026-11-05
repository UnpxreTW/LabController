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

/// 以結束碼與兩道輸出組一個結果；命令本身不影響斷言，故填佔位值。
private func result(_ exitCode: Int32, output: String = "", error: String = "") -> CommandResult {
	.init(
		command: ["scripted"],
		exitCode: exitCode,
		standardOutput: .init(output.utf8),
		standardError: .init(error.utf8)
	)
}

/// 分塊讀取腳本的輸出：先一行分隔、再 base64。前面可以混進登入 shell 印出來的雜訊。
private func chunkOutput(_ data: Data, noise: String = "") -> CommandResult {
	result(0, output: noise + "labcontroller-chunk\n" + data.base64EncodedString() + "\n")
}

/// 是不是第 `index` 項宣告的打包腳本。
private func isPacking(_ command: [String], at index: Int) -> Bool {
	command.last == "/tmp/labcontroller/artifacts/pack-\(index).sh"
}

/// 是不是分塊讀取。
private func isReading(_ command: [String]) -> Bool {
	command.count >= 3 && command[command.count - 3] == "/tmp/labcontroller/artifacts/read.sh"
}

// MARK: - JobRunnerArtifactTests

private final class JobRunnerArtifactTests {

	/// 測試共用的基底。
	private let image: GuestImage = .alias("ci-macos")

	/// 測試共用的步驟。
	private let step: JobStep = .init(name: "script", script: ["swift build"])

	/// 有宣告產物時，打包腳本與讀取腳本在開機那一刻就位；沒有宣告時不多放任何檔案。
	@Test
	private func `injects the packing and reading scripts at spawn`() async {
		let observing: ObservingBackend = .init(inner: .init())
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [.init(name: "a", paths: ["out"]), .init(name: "b", paths: ["log"])]
		)
		_ = await JobRunner(backend: observing).run(plan, on: image)
		#expect(observing.injectedPaths == [
			"/tmp/labcontroller/env.sh",
			"/tmp/labcontroller/steps/step-0.sh",
			"/tmp/labcontroller/artifacts/pack-0.sh",
			"/tmp/labcontroller/artifacts/pack-1.sh",
			"/tmp/labcontroller/artifacts/read.sh"
		])
	}

	/// 跨塊的打包檔逐塊取回、拼回來逐 byte 相同；讀取命令依序帶第幾塊。
	@Test
	private func `retrieves an archive spanning two chunks byte for byte`() async {
		let archive: Data = .init((0 ..< JobRunner.artifactChunkSize + 5).map { UInt8(truncatingIfNeeded: $0 &* 31) })
		// 打包輸出前後各混一行：前面是登入 shell 的 profile，後面是結束時的 `~/.bash_logout`。
		let packed: String = "Last login: today\nlabcontroller-packed \(archive.count)\nlogout\n"
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			if isPacking(command, at: 0) { return result(0, output: packed) }
			guard isReading(command), let index: Int = command.last.flatMap(Int.init) else { return nil }
			let start: Int = index * JobRunner.artifactChunkSize
			let end: Int = min(start + JobRunner.artifactChunkSize, archive.count)
			return chunkOutput(archive.subdata(in: start ..< end), noise: "Last login: today\n")
		}))
		let declaration: JobArtifact = .init(name: "out", paths: ["out"])
		let plan: JobPlan = .init(jobIdentifier: 1, steps: [step], timeoutSeconds: 600, artifacts: [declaration])
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(report.exitCode == 0)
		#expect(report.artifacts == [.init(declaration: declaration, archive: archive)])
		#expect(backend.executedCommands.filter(isReading).map { Array($0.suffix(2)) } == [
			["/tmp/labcontroller/artifacts/0.zip", "0"],
			["/tmp/labcontroller/artifacts/0.zip", "1"]
		])
		#expect(report.trace.contains("stage=artifacts"))
	}

	/// 一塊回來的長度不對就算收集失敗：job 本身成功時改判失敗、結束碼為 nil，不交出半份檔案。
	@Test
	private func `fails a green job when a chunk comes back short`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			if isPacking(command, at: 0) { return result(0, output: "labcontroller-packed 10\n") }
			return isReading(command) ? chunkOutput(.init(repeating: 1, count: 9)) : nil
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [.init(name: "out", paths: ["out"])]
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .jobFailed)
		#expect(report.failureReason == .scriptFailure)
		#expect(report.exitCode == nil)
		#expect(report.artifacts.isEmpty)
		#expect(report.trace.contains("預期 10 位元組、收到 9 位元組"))
	}

	/// 打包失敗時把對面說的原因留在 trace，其餘產物不再收。
	@Test
	private func `fails a green job when packing exits non-zero`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			isPacking(command, at: 0) ? result(1, error: "執行環境裡沒有 zip，產物無法打包。") : nil
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [.init(name: "a", paths: ["out"]), .init(name: "b", paths: ["log"])]
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .jobFailed)
		#expect(report.exitCode == nil)
		#expect(report.trace.contains("執行環境裡沒有 zip"))
		#expect(!backend.executedCommands.contains { isPacking($0, at: 1) })
	}

	/// 打包結果讀不懂（最後一行不是大小也不是 `none`）時同樣算失敗，不去猜大小。
	@Test
	private func `fails a green job when the packing output is unreadable`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			isPacking(command, at: 0) ? result(0, output: "labcontroller-packed \n") : nil
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [.init(name: "out", paths: ["out"])]
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .jobFailed)
		#expect(!backend.executedCommands.contains(where: isReading))
	}

	/// 一個檔案都沒有符合時只留警告：結果不變、沒有產物、也不去讀。
	@Test
	private func `leaves the result alone when no file matches`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			isPacking(command, at: 0) ? result(0, output: "labcontroller-packed none\n", error: "沒有符合 out 的檔案。") : nil
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [.init(name: "out", paths: ["out"])]
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(report.exitCode == 0)
		#expect(report.artifacts.isEmpty)
		#expect(report.trace.contains("沒有符合的檔案，不上傳"))
		#expect(!backend.executedCommands.contains(where: isReading))
	}

	/// job 已經失敗時，收產物的失敗不蓋掉原本的死因。
	@Test
	private func `keeps the step failure when collection also fails`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			if command.last?.hasSuffix("step-0.sh") == true { return result(2) }
			return isPacking(command, at: 0) ? result(1) : nil
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [.init(name: "out", paths: ["out"], uploadCondition: .always)]
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .jobFailed)
		#expect(report.exitCode == 2)
		#expect(report.trace.contains("打包失敗"))
	}

	/// job 失敗時只收 `on_failure` 與 `always` 的那幾項。
	@Test
	private func `collects only the failure and always declarations after a failure`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			command.last?.hasSuffix("step-0.sh") == true ? result(1) : result(0, output: "labcontroller-packed none\n")
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [
				.init(name: "a", paths: ["a"], uploadCondition: .onSuccess),
				.init(name: "b", paths: ["b"], uploadCondition: .onFailure),
				.init(name: "c", paths: ["c"], uploadCondition: .always)
			]
		)
		_ = await JobRunner(backend: backend).run(plan, on: image)
		let packed: [Int] = (0 ..< 3).filter { index in backend.executedCommands.contains { isPacking($0, at: index) } }
		#expect(packed == [1, 2])
	}

	/// job 成功時只收 `on_success` 與 `always` 的那幾項。
	@Test
	private func `collects only the success and always declarations after a success`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			command.last?.hasSuffix("step-0.sh") == true ? nil : result(0, output: "labcontroller-packed none\n")
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [
				.init(name: "a", paths: ["a"], uploadCondition: .onSuccess),
				.init(name: "b", paths: ["b"], uploadCondition: .onFailure),
				.init(name: "c", paths: ["c"], uploadCondition: .always)
			]
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		let packed: [Int] = (0 ..< 3).filter { index in backend.executedCommands.contains { isPacking($0, at: index) } }
		#expect(packed == [0, 2])
		#expect(report.trace.contains("略過產物 b.zip：它的上傳條件是 on_failure"))
	}

	/// 本側收不了的宣告不打包、直接算失敗，而不是少收或多收檔案照樣交出去。
	@Test(arguments: [
		JobArtifact(name: "out", paths: ["out"], exclude: ["out/tmp"]),
		JobArtifact(name: "out", untracked: true, paths: ["out"]),
		JobArtifact(name: "out", paths: ["out"], artifactType: "junit"),
		JobArtifact(name: "out", paths: ["out"], artifactFormat: "gzip"),
		JobArtifact(name: "out", paths: ["/etc"]),
		JobArtifact(name: "out", paths: ["../secret"]),
		JobArtifact(name: "out", paths: ["out/**/*.log"]),
		JobArtifact(name: "out", paths: ["build/$CI_JOB_NAME"]),
		JobArtifact(name: "out", paths: ["out"], unrecognisedUploadCondition: "sometimes"),
	])
	private func `refuses a declaration it cannot honour`(_ declaration: JobArtifact) async {
		let backend: InMemoryExecutionBackend = .init()
		let plan: JobPlan = .init(jobIdentifier: 1, steps: [step], timeoutSeconds: 600, artifacts: [declaration])
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .jobFailed)
		#expect(report.trace.contains("收不了"))
		#expect(!backend.executedCommands.contains { isPacking($0, at: 0) })
	}

	/// 步驟跑完時預算已經用完就不收：沒有步驟失敗過即判逾時。
	@Test
	private func `does not collect once the time limit has passed`() async {
		let backend: InMemoryExecutionBackend = .init()
		// 這個時鐘每問一次走 20 秒：起點、環境開起來、第一步各問一次，收產物之前那一次正好落在上限上。
		let clock: SteppingClock = .init(step: 20)
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 60,
			artifacts: [.init(name: "out", paths: ["out"])]
		)
		let report: JobRunReport = await JobRunner(backend: backend, now: clock.now).run(plan, on: image)
		#expect(report.outcome == .timeout)
		#expect(report.trace.contains("產物不再收集"))
		#expect(!backend.executedCommands.contains { isPacking($0, at: 0) })
	}

	/// 環境焚毀失敗時不改寫結果，收到的產物也一起留著。
	@Test
	private func `keeps the collected artifacts when the guest cannot be destroyed`() async {
		let archive: Data = .init("PK".utf8)
		let backend: InMemoryExecutionBackend = .init(script: .init(
			handler: { command in
				if isPacking(command, at: 0) { return result(0, output: "labcontroller-packed \(archive.count)\n") }
				return isReading(command) ? chunkOutput(archive) : nil
			},
			destroyError: .requestRejected(detail: "busy")
		))
		let declaration: JobArtifact = .init(name: "out", paths: ["out"])
		let plan: JobPlan = .init(jobIdentifier: 1, steps: [step], timeoutSeconds: 600, artifacts: [declaration])
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(report.trace.contains("環境沒能焚毀"))
		#expect(report.artifacts == [.init(declaration: declaration, archive: archive)])
	}

	/// 執行環境回報的大小超過上限時不去讀，直接算收集失敗。
	@Test
	private func `refuses an archive larger than the limit`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			isPacking(command, at: 0) ? result(0, output: "labcontroller-packed \(Int.max)\n") : nil
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [.init(name: "out", paths: ["out"])]
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .jobFailed)
		#expect(report.trace.contains("超過上限"))
		#expect(!backend.executedCommands.contains(where: isReading))
	}

	/// 讀不懂的上傳條件在 job 失敗時也照實寫出，不被當成回落後的 `on_success` 略過。
	@Test
	private func `reports an unreadable condition even after a failure`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			command.last?.hasSuffix("step-0.sh") == true ? result(4) : nil
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [step],
			timeoutSeconds: 600,
			artifacts: [.init(name: "out", paths: ["out"], unrecognisedUploadCondition: "weird")]
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.exitCode == 4)
		#expect(report.trace.contains("上傳條件 weird 讀不懂"))
		#expect(!report.trace.contains("略過產物"))
	}

	/// 併入上傳結果時，產物原樣帶著——不論終態有沒有被改寫。
	@Test(arguments: [false, true])
	private func `upload summary keeps the collected artifacts`(_ hasFailed: Bool) {
		let artifact: CollectedArtifact = .init(declaration: .init(name: "out"), archive: .init("PK".utf8))
		let report: JobRunReport = .init(outcome: .completed, exitCode: 0, artifacts: [artifact])
		let merged: JobRunReport = JobArtifactUploadSummary(hasFailed: hasFailed).applied(to: report)
		#expect(merged.artifacts == [artifact])
	}

	/// 真的跑一次：bash、`zip`、`dd`、`base64` 拼回來的是一份只含符合檔案的 zip，含單引號與空白
	/// 的路徑也照字面展開。
	@Test
	private func `packs and retrieves a real archive through the shell`() async throws {
		let root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("labctl-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: root) }
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [.init(name: "script", script: [
				"mkdir -p out",
				"printf hello > \"out/it's here.txt\"",
				"printf world > out/skip.log"
			])],
			timeoutSeconds: 600,
			artifacts: [.init(name: "out", paths: ["out/it's here*", "missing/*"])]
		)
		let runner: JobRunner = .init(
			backend: LocalShellBackend(),
			configuration: .init(workspaceRoot: root.path, shell: ["/bin/bash"])
		)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(report.trace.contains("沒有符合 missing/* 的檔案"))
		let archive: Data = try #require(report.artifacts.first?.archive)
		let archiveURL: URL = root.appendingPathComponent("retrieved.zip")
		try archive.write(to: archiveURL)
		let listing: CommandResult = try await LocalShellBackend().exec(
			["/usr/bin/unzip", "-Z1", archiveURL.path],
			in: .init("local-1")
		)
		#expect(listing.standardOutputText.split(separator: "\n") == ["out/it's here.txt"])
	}
}
