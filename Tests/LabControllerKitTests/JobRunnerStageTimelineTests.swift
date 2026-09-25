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

// MARK: - JobRunnerStageTimelineTests

private final class JobRunnerStageTimelineTests {

	/// 測試共用的基底。
	private let image: GuestImage = .alias("ci-linux")

	/// 測試共用的取碼座標。
	private let git: GitInfo = .init(repoURL: "https://gitlab.example/group/project.git", ref: "main", sha: "deadbeef")

	/// 一件正常跑完的 job 在 trace 上留下一整張時間表，每一段一行、依序出現。
	///
	/// 這正是這一片要的東西：事後只看 trace 就答得出「那三十分鐘落在哪一段」，而不是像
	/// 之前那樣只看得到一個終態。
	@Test
	private func `marks every stage of a job that runs to the end`() async {
		let backend: InMemoryExecutionBackend = .init()
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			git: git,
			steps: [
				.init(name: "resolve dependencies", script: ["swift package resolve"]),
				.init(name: "build", script: ["swift build"]),
				.init(name: "test", script: ["swift test"])
			],
			timeoutSeconds: 600
		)
		let clock: SteppingClock = .init(step: 5)
		let report: JobRunReport = await JobRunner(backend: backend, now: clock.now).run(plan, on: image)
		#expect(report.outcome == .completed)
		#expect(
			Self.stages(in: report.trace)
				== ["workspace", "guest", "checkout", "step[0]", "step[1]", "step[2]", "finish"]
		)
	}

	/// 時間表上的時刻單調不回頭，且 `elapsed` 自原點起算。
	///
	/// 兩件事一起驗：時刻本身若會回頭，這張表拿來算「哪一段最久」就會算出負數；而 `elapsed`
	/// 若不是從同一個原點起算，兩行相減得到的也不是那一段的長度。
	@Test
	private func `keeps the timeline monotonic and anchored at the first mark`() async {
		let backend: InMemoryExecutionBackend = .init()
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			git: git,
			steps: [.init(name: "build", script: ["swift build"])],
			timeoutSeconds: 600
		)
		let clock: SteppingClock = .init(step: 7)
		let report: JobRunReport = await JobRunner(backend: backend, now: clock.now).run(plan, on: image)
		let elapsed: [Double] = Self.elapsedSeconds(in: report.trace)
		#expect(elapsed.count == 5)
		#expect(elapsed.first == 0)
		#expect(elapsed == elapsed.sorted())
		// 每問一次時鐘走七秒，而五段標記各佔恰好一次：最後一段因此落在第四步上。
		#expect(elapsed.last == 28)
	}

	/// 沒有取碼座標的 job 不會憑空多出一段取碼。
	///
	/// 時間表要拿來對帳，多一段不存在的等於讓讀表的人去找一段根本沒發生過的事。
	@Test
	private func `leaves out the checkout stage when the job carries no coordinates`() async {
		let backend: InMemoryExecutionBackend = .init()
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [.init(name: "build", script: ["swift build"])],
			timeoutSeconds: 600
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(Self.stages(in: report.trace) == ["workspace", "guest", "step[0]", "finish"])
	}

	/// 略過的步驟不留標記：那一段沒有發生，時間表上也就不該有它。
	@Test
	private func `skips the mark of a step that never runs`() async {
		let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
			command.last?.hasSuffix("step-0.sh") == true ? CommandResult(command: command, exitCode: 2) : nil
		}))
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			steps: [
				.init(name: "build", script: ["swift build"]),
				.init(name: "publish", script: ["deploy"]),
				.init(name: "cleanup", script: ["rm -rf tmp"], runCondition: .always)
			],
			timeoutSeconds: 600
		)
		let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
		#expect(report.outcome == .jobFailed)
		#expect(Self.stages(in: report.trace) == ["workspace", "guest", "step[0]", "step[2]", "finish"])
	}

	/// 一個執行環境都沒開成的 job，時間表仍以收尾那一行結束。
	///
	/// 少了最後一行，讀表的人分不出「這件 job 沒跑到收尾」與「紀錄本身斷在半路」。
	@Test
	private func `closes the timeline even when no environment ever opens`() async {
		let inner: InMemoryExecutionBackend = .init()
		let backend: CapacityLimitedBackend = .init(inner: inner, refusals: 99)
		let plan: JobPlan = .init(
			jobIdentifier: 1,
			git: git,
			steps: [.init(name: "build", script: ["swift build"])],
			timeoutSeconds: 60
		)
		// 一問一步的假時鐘：等一輪之後時間就超過上限，不靠睡去逼近它。
		let clock: SteppingClock = .init(step: 45)
		let runner: JobRunner = .init(backend: backend, waitBeforeRetry: { _ in }, now: clock.now)
		let report: JobRunReport = await runner.run(plan, on: image)
		#expect(report.outcome == .systemFailed)
		#expect(Self.stages(in: report.trace) == ["workspace", "finish"])
	}

	/// 時間表這幾行的開頭；事後靠它把表自 trace 裡篩出來。
	private static let prefix: String = "[lab_controller] stage="

	/// 自一份 trace 取出時間表上的段名，依出現順序。
	private static func stages(in trace: String) -> [String] {
		fields(in: trace).compactMap { $0["stage"] }
	}

	/// 自一份 trace 取出各段的 `elapsed` 秒數，依出現順序。
	private static func elapsedSeconds(in trace: String) -> [Double] {
		fields(in: trace).compactMap { fields in
			guard let value: String = fields["elapsed"] else { return nil }
			return .init(value.dropLast())
		}
	}

	/// 把時間表那幾行切成逐欄的字典；不是時間表的行一概不收。
	private static func fields(in trace: String) -> [[String: String]] {
		trace
			.split(separator: "\n")
			.filter { $0.hasPrefix(prefix) }
			.map { line in
				var fields: [String: String] = [:]
				for token: Substring in line.split(separator: " ") {
					let parts: [Substring] = token.split(separator: "=", maxSplits: 1)
					guard parts.count == 2 else { continue }
					fields[.init(parts[0])] = .init(parts[1])
				}
				return fields
			}
	}
}
