//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Logging

/// 把打包好的產物逐份送上站台；站台暫時收不下時照 runner 端的次數與節奏重送。
///
/// 次數與節奏照 gitlab-runner v16.2（`commands/helpers/artifacts_uploader.go` 與 `helpers/retry`）：
/// 每份最多送 3 次，站台回 503 時放寬到 6 次（上限看的是最近一次的原因）；兩次之間從 1 秒起倍增、
/// 最多 5 秒。403 與 413 不重送——重送的結果不會不同。
///
/// **一份送不上去就不送後面的**：那一刻這件 job 的終態已經定成失敗，後面幾份送上去也改變不了
/// 結果，只是多佔一段時間。
///
/// **307 不跟**：runner 端會改送到 `Location` 指的站台，但那等於讓站台的回應決定 job token 送去
/// 哪一台主機；傳輸層不跟隨轉址的理由（見 ``URLSessionTransport``）在這裡同樣成立。
///
/// - Important: `client` 要用 ``URLSessionTransport/init(artifactUploadResourceTimeout:)`` 建的傳輸：
///   共用傳輸把每個請求的整體時長夾在 600 秒，一份大的產物會在途中被切斷。
public struct JobArtifactUploader: Sendable {

	// MARK: Public

	/// 每份產物最多送幾次（含第一次）。
	public static let attemptLimit: Int = 3

	/// 站台回 503 時，每份產物最多送幾次（含第一次）。
	public static let serviceUnavailableAttemptLimit: Int = 6

	/// 第幾次重送之前要等多久，秒：從 1 秒起倍增、最多 5 秒。
	///
	/// - Parameter retry: 第幾次重送，從 1 起算。
	/// - Returns: 等待秒數。
	public static func delay(beforeRetry retry: Int) -> TimeInterval {
		min(pow(2, TimeInterval(max(retry, 1) - 1)), 5)
	}

	/// 送產物用的 client。
	public let client: JobRequestClient

	/// 逐份送出；送到第一份失敗為止。
	///
	/// - Parameters:
	///   - artifacts: 要送的產物，依序送。
	///   - target: 回寫座標；用的是這件 job 的專屬 token。
	///   - masker: trace 行的遮蔽規則；檔名由 payload 而來，可能帶著變數展開後的值。
	/// - Returns: 要接進 trace 的幾行與有沒有送失敗；沒有產物時為空的結果。
	public func upload(
		_ artifacts: [CollectedArtifact],
		to target: JobReportTarget,
		masker: TraceMasker
	) async -> JobArtifactUploadSummary {
		var lines: [String] = []
		for artifact in artifacts {
			let filename: String = artifact.declaration.uploadFilename
			lines.append("上傳產物 \(filename)（\(artifact.archive.count) 位元組）。")
			guard let reason: String = await send(artifact, to: target, recording: &lines) else {
				lines.append("產物 \(filename) 已上傳。")
				continue
			}
			lines.append("產物 \(filename) 上傳失敗：\(reason)。其餘產物不再上傳。")
			// 不帶檔名：檔名由 payload 而來，這一行只需要指出是哪一件 job、為什麼。
			logger.log(level: .warning, "job \(target.identifier) artifact upload failed: \(masker.mask(reason))")
			return .init(traceLines: lines.map(masker.mask), hasFailed: true)
		}
		return .init(traceLines: lines.map(masker.mask))
	}

	/// 逐欄建立。
	///
	/// - Parameters:
	///   - client: 送產物用的 client。
	///   - wait: 兩次送出之間等待的方式；不給即真的睡指定秒數。
	///   - logger: 紀錄出口；不給即取行程裝上的那一份。
	public init(
		client: JobRequestClient,
		wait: @escaping @Sendable (TimeInterval) async -> Void = JobPollingLoop.sleep,
		logger: Logger = .init(label: "lab-controller")
	) {
		self.client = client
		self.wait = wait
		self.logger = logger
	}

	// MARK: Private

	/// 兩次送出之間等待的方式；測試注入不真的睡的版本。
	private let wait: @Sendable (TimeInterval) async -> Void

	/// 紀錄出口；只寫哪一件 job、為什麼失敗，不寫檔名與檔案內容。
	private let logger: Logger

	/// 送一份產物，必要時重送。
	///
	/// - Parameters:
	///   - artifact: 要送的產物。
	///   - target: 回寫座標。
	///   - lines: 每一次重送前寫一行說明。
	/// - Returns: 送上去時為 nil；最終沒送上去時為原因。
	private func send(
		_ artifact: CollectedArtifact,
		to target: JobReportTarget,
		recording lines: inout [String]
	) async -> String? {
		var attempt: Int = 1
		while true {
			let reason: String
			let limit: Int
			do {
				switch try await client.uploadArtifact(
					host: target.host,
					jobID: target.identifier,
					jobToken: target.token,
					artifact: artifact.declaration,
					archive: artifact.archive
				) {
				case .uploaded:
					return nil
				case .forbidden:
					return "站台拒收（job 已不在執行中，或 job token 已失效）"
				case .tooLarge:
					return "檔案超過站台允許的大小"
				case .redirected:
					// 不印 `Location`：那是站台回應裡的網址，可能帶著不該進 trace 的東西。
					return "站台要求改送到另一個位址，本 runner 不跟隨轉址"
				case .serviceUnavailable:
					reason = "站台暫時無法處理（503）"
					limit = Self.serviceUnavailableAttemptLimit
				case let .failed(statusCode):
					reason = "站台回應 \(statusCode)"
					limit = Self.attemptLimit
				}
			} catch {
				// 經 `safeDescription` 再寫：連不上時的錯誤原樣帶著整條網址，站台位址的 userinfo 段收得下憑證。
				reason = "連線失敗：\(GitLabAPIError.safeDescription(of: error))"
				limit = Self.attemptLimit
			}
			guard attempt < limit else { return reason }
			let delay: TimeInterval = Self.delay(beforeRetry: attempt)
			lines.append("產物 \(artifact.declaration.uploadFilename) 這次沒送上去（\(reason)），\(Int(delay)) 秒後重送。")
			await wait(delay)
			attempt += 1
		}
	}
}
