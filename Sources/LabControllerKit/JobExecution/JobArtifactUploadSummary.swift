//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一件 job 的產物上傳完之後要交回去的東西：寫進 trace 的那幾行，以及有沒有送失敗。
public struct JobArtifactUploadSummary: Sendable, Equatable {

	/// 要接在 trace 後面的幾行；已過遮蔽，一個元素一行、不含換行字元。
	public let traceLines: [String]

	/// 有沒有任何一份產物最終沒送上去。
	public let hasFailed: Bool

	/// 把上傳結果併進這件 job 的結果。
	///
	/// trace 一律接上；終態只在「job 本身成功、上傳卻失敗」時改寫成 job 失敗（`script_failure`，
	/// 結束碼為 nil）。job 本身已經失敗時保留原本的死因：上傳失敗是後來才發生的事，拿它蓋掉步驟
	/// 的失敗，站台端看到的就不是真正的原因——runner 端（gitlab-runner v16.2 `common/build.go` 的
	/// `pickPriorityError`）也是 job 的錯優先、上傳的錯其次。
	///
	/// - Parameter report: 跑完的結果。
	/// - Returns: 併入上傳結果之後的結果。
	public func applied(to report: JobRunReport) -> JobRunReport {
		var trace: String = report.trace
		if !traceLines.isEmpty, !trace.isEmpty, !trace.hasSuffix("\n") {
			trace += "\n"
		}
		trace += traceLines.map { $0 + "\n" }.joined()
		guard hasFailed, report.outcome == .completed else {
			return .init(
				outcome: report.outcome,
				failureReason: report.failureReason,
				exitCode: report.exitCode,
				trace: trace,
				warnings: report.warnings,
				artifacts: report.artifacts
			)
		}
		return .init(
			outcome: .jobFailed,
			failureReason: .scriptFailure,
			exitCode: nil,
			trace: trace,
			warnings: report.warnings,
			artifacts: report.artifacts
		)
	}

	/// 逐欄建立；兩欄皆有預設值（沒有產物要送時即為空的結果）。
	///
	/// - Parameters:
	///   - traceLines: 已過遮蔽的 trace 行。
	///   - hasFailed: 有沒有送失敗。
	public init(traceLines: [String] = [], hasFailed: Bool = false) {
		self.traceLines = traceLines
		self.hasFailed = hasFailed
	}

}
