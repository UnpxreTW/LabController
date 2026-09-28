//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LabControllerKit
import Testing

// MARK: - JobRunnerTraceRecorderTests

/// 抄本收攏之後的行為：時間表關上、普通行照收。
///
/// 測試資料全為合成字串，不含任何真實憑證。
private final class JobRunnerTraceRecorderTests {

	/// 收攏之後再標一段也不會落行：時間表只收一次尾。
	///
	/// 寬限到期那條路徑會讓收尾與被放手的那段工作同時在寫。沒有這道閘時，表上會多出落在收尾
	/// 之後的段、甚至第二行收尾，而這張表本來是要被排成一張時間表來讀的。
	@Test
	private func `takes no further stage once the trace is collected`() {
		let recorder: JobRunner.TraceRecorder = .init(masker: .init(maskedValues: []))
		let instant: Date = .init(timeIntervalSince1970: 0)
		recorder.mark("guest", at: instant)
		recorder.mark("finish", at: instant.addingTimeInterval(1))
		_ = recorder.finish()
		recorder.mark("step[0]", at: instant.addingTimeInterval(2))
		recorder.mark("finish", at: instant.addingTimeInterval(3))
		#expect(Self.stages(in: recorder.finish()) == ["guest", "finish"])
	}

	/// 收攏之後仍收得下普通行：收拾那一側要補的說明不能跟著時間表一起被關掉。
	@Test
	private func `still takes plain lines after the trace is collected`() {
		let recorder: JobRunner.TraceRecorder = .init(masker: .init(maskedValues: []))
		recorder.mark("finish", at: .init(timeIntervalSince1970: 0))
		_ = recorder.finish()
		recorder.write("環境沒能焚毀：unknown guest")
		let trace: String = recorder.finish()
		#expect(trace.contains("環境沒能焚毀：unknown guest"))
		#expect(Self.stages(in: trace) == ["finish"])
	}

	/// 時間表這幾行的開頭；靠它把表自一份 trace 裡篩出來。
	private static let prefix: String = "[lab_controller] stage="

	/// 自一份 trace 取出時間表上的段名，依出現順序。
	private static func stages(in trace: String) -> [String] {
		trace
			.split(separator: "\n")
			.filter { $0.hasPrefix(prefix) }
			.compactMap { line in
				line
					.split(separator: " ")
					.first { $0.hasPrefix("stage=") }
					.map { String($0.dropFirst("stage=".count)) }
			}
	}
}
