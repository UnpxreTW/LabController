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

/// 測試共用的迴圈設定；站台位址與 token 皆為合成值。
internal let pollingLoopConfiguration: JobPollingLoop.Configuration = .init(
	host: "https://gitlab.example.invalid",
	runnerToken: "synthetic-runner-token",
	image: .alias("golden-xcode")
)

/// 測試共用的回寫座標；全為合成值。
internal let syntheticReportTarget: JobReportTarget = .init(
	host: "https://gitlab.example.invalid",
	identifier: 7,
	token: "synthetic-job-token"
)

/// 從請求本體解出 JSON 物件；解不出即測試失敗。
///
/// - Parameter request: 送出的請求。
/// - Returns: 本體解出的 JSON 物件。
/// - Throws: 沒有本體、或本體不是 JSON 物件時，由 `#require` 拋出。
internal func requestBody(of request: HTTPRequest) throws -> [String: Any] {
	let data: Data = try #require(request.body)
	return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}
