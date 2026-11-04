//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// `POST /api/v4/jobs/:id/artifacts` 的站台回應，依「接下來該怎麼辦」分類。
///
/// 分類對應 runner 端（gitlab-runner v16.2 `network/gitlab.go` 的 `determineUploadState`），唯一差別
/// 是 307 缺 `Location` 時：runner 端判成失敗，這裡回 ``redirected(location:)``（值為 nil）、交給呼叫端決定。
/// 只有 201 是收下；其餘每一種都不是收下，但後續處置不同——重試有沒有意義、要不要換位址，
/// 由呼叫端依這裡的分類決定。**這一層不重試**，理由同 ``JobRequestClient/updateJob(host:jobID:jobToken:state:failureReason:exitCode:)``：
/// 重試的節奏與次數是呼叫端對整件 job 的判斷，不是協議層的事。
public enum ArtifactUploadResult: Sendable, Equatable {

	/// 201：站台收下了。
	case uploaded

	/// 307：站台要求改送到另一個位址；`location` 為回應標頭原值，沒帶時為 nil。
	case redirected(location: String?)

	/// 403：job 已不在執行中（取消／已結束），或 job token 失效；重送不會有不同結果。
	case forbidden

	/// 413：檔案超過站台允許的大小；重送不會有不同結果。
	case tooLarge

	/// 503：站台暫時無法處理；隔一段時間重送可能成功。
	case serviceUnavailable

	/// 其餘狀態碼；附上原值，供紀錄與判斷是否重試。
	case failed(statusCode: Int)
}
