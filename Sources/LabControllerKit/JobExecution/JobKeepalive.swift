//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Logging

/// 跑 job 的期間定期向站台報一聲「這件還在跑」，站台已經不讓它跑時喊停。
///
/// 回寫只在 job 跑完之後才送（見 ``JobResultReporter``），跑的那一整段本側與站台之間沒有任何
/// 往來。這段沉默有兩個後果：站台端看不到這台 runner 還在處理那件 job，以及**站台端取消了
/// 這件 job，這一側也不會知道**——取消只會浮現在下一次回報的回應裡，沒有下一次回報，被取消的
/// job 會在環境裡一路跑到自己的時間上限。
///
/// 每一輪送的是 `PUT /jobs/:id`、狀態 `running`，不帶 trace。站台回 403、或回應標頭
/// `Job-Status` 表示 job 已不在執行中（判準同 ``JobUpdateAck/isAborted``）時，按下交進來的
/// 那支 ``StopSignal``，由跑 job 的那一層焚毀環境收場（見 ``JobRunner``）。判準只看回應本身
/// 帶了什麼，不看站台版本：舊版站台對執行中的 job 回 200，該標頭不帶或為 `running`，這條路徑
/// 在那裡就只是一聲照常的回報。
///
/// - Important: **連線失敗不喊停**。站台或網路暫時不在時，回報送不出去不代表 job 被取消；
///   在這裡喊停會把一件好好在跑的 job 砍掉，而站台端看到的是一件莫名其妙以環境錯收場的 job。
///   下一輪照常再送。
public struct JobKeepalive: Sendable {

	// MARK: Public

	/// 預設的回報間隔（秒）。
	///
	/// 取一分鐘：這個值決定站台端取消之後，這一側最晚多久察覺——每一輪只是一個不帶 trace 的
	/// 小請求，間隔放長省不了什麼，察覺得慢卻代表一件已取消的 job 多佔一段環境。
	public static let defaultInterval: TimeInterval = 60

	/// 間隔的上限（秒）：十分鐘。
	///
	/// 設定給得再大也收在這裡：間隔就是站台端取消之後、這一側察覺之前的最長空窗，也是站台端
	/// 收不到這台 runner 任何消息的最長一段。
	public static let maximumInterval: TimeInterval = 600

	/// 協議層 client。
	public let client: JobRequestClient

	/// 回報座標；用的是站台隨這件 job 發的專屬 token，不是 runner 認證 token。
	public let target: JobReportTarget

	/// 實際採用的回報間隔；已收在一秒到 ``maximumInterval`` 之間。
	public let interval: TimeInterval

	/// 每隔一段送一次回報，直到被取消、或站台表示這件 job 已不在執行中。
	///
	/// 先等一段再送第一次：剛領到的 job 站台端本來就記為執行中，一領到就報等於多送一次。
	///
	/// - Parameters:
	///   - cancellation: 站台表示 job 已不在執行中時要按下的那支訊號；只按一次，按完就回來。
	///   - logger: 紀錄出口；**這條路徑不帶任何 token**，錯誤一律經
	///     ``GitLabAPIError/safeDescription(of:)`` 收斂後才印。
	public func run(signaling cancellation: StopSignal, logger: Logger) async {
		while !Task.isCancelled {
			await wait(interval)
			guard !Task.isCancelled else { return }
			let acknowledgement: JobUpdateAck
			do {
				acknowledgement = try await client.updateJob(
					host: target.host,
					jobID: target.identifier,
					jobToken: target.token,
					state: .running
				)
			} catch {
				// 被取消而回來的那一次不是故障：job 已經跑完、上層正在收這一支。
				guard !Task.isCancelled else { return }
				logger.warning(
					"job \(target.identifier) keepalive failed: \(GitLabAPIError.safeDescription(of: error))"
				)
				continue
			}
			guard acknowledgement.isAborted else { continue }
			let statusCode: String = acknowledgement.statusCode.map(String.init) ?? "-"
			let jobStatus: String = acknowledgement.jobStatus ?? "-"
			logger.warning(
				"job \(target.identifier) is no longer running on the server (status \(statusCode), job \(jobStatus))"
			)
			cancellation.stop()
			return
		}
	}

	/// 逐欄建立。
	///
	/// - Parameters:
	///   - client: 協議層 client。
	///   - target: 回報座標。
	///   - interval: 回報間隔（秒）；大於 ``maximumInterval`` 時以上限計，小於一秒時以一秒計——
	///     間隔為零等於對站台打一串緊迴圈。
	///   - wait: 兩次回報之間等待的方式；預設真的睡指定秒數，被取消時立刻回來。
	public init(
		client: JobRequestClient,
		target: JobReportTarget,
		interval: TimeInterval = JobKeepalive.defaultInterval,
		wait: @escaping @Sendable (TimeInterval) async -> Void = JobPollingLoop.sleep
	) {
		self.client = client
		self.target = target
		self.interval = min(max(interval, 1), Self.maximumInterval)
		self.wait = wait
	}

	// MARK: Private

	/// 兩次回報之間等待的方式；測試靠它決定什麼時候送下一次、不真的睡。
	private let wait: @Sendable (TimeInterval) async -> Void
}
