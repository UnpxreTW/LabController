//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 產物上傳專用的傳輸：與領件、trace、狀態回寫共用的那一份 session 分開，整體時長另計。
///
/// 共用的那一份（``URLSessionTransport/init()``）把單一請求的整體時長夾在 600 秒，那是給短請求
/// 用的保險絲。產物是整份檔案在同一個請求裡送出，檔案一大、網路一慢，超過 600 秒是正常情況；
/// 算在同一個上限裡，一件已經跑完的 job 會在上傳途中被切斷，然後以上傳失敗收場。上傳因此另開
/// 一個 session，它的整體上限由 ``init(artifactUploadResourceTimeout:)`` 的參數決定，與 600 秒互不相干。
extension URLSessionTransport {

	/// 一次上傳從送出到收完回應的預設上限，秒（2 小時）。
	///
	/// 只是一道防止連線卡死的保險絲，不是對產物大小的限制：一份產物送得多慢都可以，只要在這段時間內
	/// 送完。要更長就在建立時給更大的值。
	public static let defaultArtifactUploadResourceTimeout: TimeInterval = 7200

	/// 建立產物上傳專用的傳輸。
	///
	/// 轉址一樣不跟隨、快取一樣不用：送出請求那一段與共用的那一份是同一條路（見 ``URLSessionTransport``），
	/// 只有 session 的整體時長不同。
	///
	/// - Important: 每建一次就多一個 session（連同它自己的連線池），且行程結束前不會釋放——行程內建
	///   一次、重複使用，不要每件 job 各建一個。
	/// - Parameter resourceTimeout: 一次上傳從送出到收完回應的上限，秒；不大於 0 時取
	///   ``defaultArtifactUploadResourceTimeout``。
	public init(artifactUploadResourceTimeout resourceTimeout: TimeInterval) {
		self.init(session: .init(configuration: Self.artifactUploadConfiguration(resourceTimeout: resourceTimeout)))
	}

	/// 上傳專用 session 的組態；除了整體時長，其餘與共用的那一份相同。
	///
	/// - Parameter resourceTimeout: 一次上傳的整體上限，秒；不大於 0 時取預設值。
	/// - Returns: 新的組態。
	internal static func artifactUploadConfiguration(resourceTimeout: TimeInterval) -> URLSessionConfiguration {
		let configuration: URLSessionConfiguration = .default
		configuration
			.timeoutIntervalForResource = resourceTimeout > 0 ? resourceTimeout : defaultArtifactUploadResourceTimeout
		configuration.waitsForConnectivity = false
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.urlCache = nil
		return configuration
	}
}
