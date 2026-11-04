//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// runner 協議中「領 job → 回寫 log → 上傳產物 → 回報成敗」四支端點的 client。
///
/// 與 `RunnerRegistrationClient` 平行、不共用型別：註冊用 registration token 換
/// runner 認證 token，本 client 則用 runner 認證 token 領 job、再用 job 專屬 token
/// 回寫。兩者 token 域不同，混用即為權限錯置。
///
/// 本片只到協議層——領到 job 之後怎麼跑（VM、clone、script）由後續切片承接。
///
/// 形狀依據：GitLab 16.2 的 `lib/api/ci/runner.rb`、`workhorse/internal/builds/register.go`、
/// `app/services/ci/register_job_service.rb`，以及 gitlab-runner v16.2 的
/// `network/gitlab.go`（此組屬 runner 內部 API、官方文件不完整、以原始碼為準）。
public struct JobRequestClient: Sendable {

	/// long-poll 的請求逾時；必須大於站台端 hold 的時間（實測約 50 秒），
	/// 否則 client 會自己先斷、白費被 hold 的連線又反覆敲站台。
	public static let jobRequestTimeout: TimeInterval = 75

	/// 一般請求（trace／狀態回報）的逾時；這類應快速失敗。
	public static let standardTimeout: TimeInterval = 30

	/// 產物上傳的逾時；整份檔案在同一個請求裡送出，不能沿用一般請求的短逾時。
	///
	/// - Warning: 這是每個請求的閒置上限，不是總時長上限：正式傳輸（`URLSessionTransport`）的
	///   session 另有 600 秒的整體上限，一次上傳從送出到收完回應超過 600 秒就會被中斷，不論本值設多少。
	public static let artifactUploadTimeout: TimeInterval = 600

	/// 傳輸層；正式路徑用 `URLSessionTransport`、測試注入假傳輸。
	private let transport: any HTTPTransport

	/// 以指定傳輸建立；未指定時採 URLSession 正式路徑。
	public init(transport: any HTTPTransport = URLSessionTransport()) {
		self.transport = transport
	}

	/// `POST /api/v4/jobs/request`：long-poll 領一個 job。
	///
	/// 201＝指派了 job；204＝此刻無 job（正常路徑、非錯誤）。
	///
	/// `lastUpdate` 必須放進 **JSON body**（不是請求標頭）——Workhorse 的
	/// `RegisterHandler` 從 body 取 `last_update`，取不到就直接把請求 proxy 給
	/// Rails、**完全不 hold**，long-poll 等於沒開。回傳的游標已與傳入值合併
	/// （站台只在 204 分支發新游標），可直接沿用。
	///
	/// `info` 的能力宣告會影響站台指派：宣告不足會讓需要該能力的 job 被
	/// `drop!`（見 `RunnerFeatures`），務必如實填寫。
	public func requestJob(
		host: String,
		token: String,
		lastUpdate: String? = nil,
		info: RunnerInfo = .init()
	) async throws -> JobRequestResult {
		let payload: JobRequestPayload = .init(token: token, lastUpdate: lastUpdate, info: info)
		let response: HTTPResponse = try await send(
			method: "POST",
			host: host,
			path: "jobs/request",
			headers: ["Content-Type": "application/json"],
			body: try JSONEncoder().encode(payload),
			timeout: Self.jobRequestTimeout
		)
		// 站台只在 204 分支發游標；沒收到就沿用舊值，別覆寫成 nil。
		let cursor: String? = response.headerValue("X-GitLab-Last-Update") ?? lastUpdate
		switch response.statusCode {
		case 201:
			// 走 do/catch 而非 `try?`：`JobResponse` 現在只有 `id`／`token` 缺席才會走到這裡，
			// 而缺哪一個決定了下一步。`try?` 把那個資訊丟掉，log 上只剩「body 解不開」。
			do {
				let job: JobResponse = try JSONDecoder().decode(JobResponse.self, from: response.body)
				return .init(outcome: .assigned(job), lastUpdate: cursor)
			} catch {
				throw GitLabAPIError.undecodableBody(codingPath: Self.codingPath(of: error))
			}
		case 204:
			return .init(outcome: .noJob, lastUpdate: cursor)
		default:
			throw GitLabAPIError.unexpectedStatus(response.statusCode)
		}
	}

	/// `PATCH /api/v4/jobs/:id/trace`：把一段增量 log 附加到 job 的輸出。
	///
	/// `startOffset` 是這段內容在整份 log 中的起始 byte 位移，`Content-Range` 以
	/// **閉區間**表達（`start-(start+count-1)`、與 runner 實作一致）。
	///
	/// 416 與 403 **不當成錯誤拋出**：416 的 `Range` 標頭帶著站台實際收到的位置，
	/// 是位移對不上時唯一的重同步依據。403 代表 job 已非 running（取消／已結束）
	/// 或 token 失效／trace 超限；**取消造成的 403 帶 `Job-Status`、其餘不帶**，
	/// 故以 `TraceAck.isAborted`（狀態碼為主判準）呈現。呼叫端必須據此停止回寫，
	/// 不可當成普通 ack 繼續灌 log（會一路灌進黑洞、到回報終態才發現）。
	public func appendTrace(
		host: String,
		jobID: Int,
		jobToken: String,
		chunk: Data,
		startOffset: Int
	) async throws -> TraceAck {
		guard !chunk.isEmpty else {
			return .init()
		}
		let endOffset: Int = startOffset + chunk.count - 1
		let response: HTTPResponse = try await send(
			method: "PATCH",
			host: host,
			path: "jobs/\(jobID)/trace",
			headers: [
				"Content-Type": "text/plain",
				"Content-Range": "\(startOffset)-\(endOffset)",
				"JOB-TOKEN": jobToken,
			],
			body: chunk,
			timeout: Self.standardTimeout
		)
		let status: String? = response.headerValue("Job-Status")
		let interval: TimeInterval? = response.headerValue("X-GitLab-Trace-Update-Interval")
			.flatMap(TimeInterval.init)
		let offset: Int? = Self.nextOffset(from: response.headerValue("Range"))
		switch response.statusCode {
		case 200 ... 202:
			return .init(
				jobStatus: status, nextOffset: offset,
				updateInterval: interval, statusCode: response.statusCode
			)
		case 416:
			return .init(
				jobStatus: status, nextOffset: offset, needsResync: true,
				updateInterval: interval, statusCode: response.statusCode
			)
		case 403:
			// job 已非 running（取消／已結束）、token 失效，或 trace 超限被 drop。
			// 只有「job 非 running」那條帶 Job-Status、其餘不帶 → 靠狀態碼判 isAborted。
			return .init(
				jobStatus: status, nextOffset: offset,
				updateInterval: interval, statusCode: response.statusCode
			)
		default:
			throw GitLabAPIError.unexpectedStatus(response.statusCode)
		}
	}

	/// `PUT /api/v4/jobs/:id`：回報 job 的狀態或終態。
	///
	/// **200 才是「已寫入」**；202 代表站台收下但尚未完成（trace 未落地），必須依
	/// `updateInterval` 重送，否則 job 會一直掛在 running。回傳的
	/// `JobUpdateAck.isCompleted` 就是這個區別。
	///
	/// 403 **不當成錯誤拋出**：它代表 job 已非 running（取消／已結束）或 token
	/// 失效。對「沒有新 log 可送的安靜 job」，這條 keepalive 403 是取消唯一會浮現
	/// 的地方（`authenticate_job!` → `job_forbidden!` 會先帶 `Job-Status`），
	/// 丟掉就等於看不見取消。以 `JobUpdateAck.isAborted` 呈現、與 trace 那支對稱。
	///
	/// `failureReason` 只在 `state` 為 `.failed` 時有意義；它決定站台端要不要重試
	/// （程式錯不重試、環境錯可重試）。
	public func updateJob(
		host: String,
		jobID: Int,
		jobToken: String,
		state: JobState,
		failureReason: JobFailureReason? = nil,
		exitCode: Int? = nil
	) async throws -> JobUpdateAck {
		let payload: JobUpdatePayload = .init(
			token: jobToken,
			state: state.rawValue,
			failureReason: failureReason?.rawValue,
			exitCode: exitCode
		)
		let response: HTTPResponse = try await send(
			method: "PUT",
			host: host,
			path: "jobs/\(jobID)",
			headers: ["Content-Type": "application/json"],
			body: try JSONEncoder().encode(payload),
			timeout: Self.standardTimeout
		)
		let status: String? = response.headerValue("Job-Status")
		let interval: TimeInterval? = response.headerValue("X-GitLab-Trace-Update-Interval")
			.flatMap(TimeInterval.init)
		switch response.statusCode {
		case 200:
			return .init(
				isCompleted: true, jobStatus: status,
				updateInterval: interval, statusCode: response.statusCode
			)
		case 202:
			return .init(
				isCompleted: false, jobStatus: status,
				updateInterval: interval, statusCode: response.statusCode
			)
		case 403:
			// job 已非 running（取消／已結束）或 token 失效。取消造成的 403 帶
			// Job-Status、token 造成的不帶——一律以 isAborted 呈現，不 throw 掉，
			// 否則呼叫端看到的與連線層錯誤無異、多半會當暫時性失敗重試，
			// 讓 VM 與 script 一路跑到 job timeout。
			return .init(
				isCompleted: false, jobStatus: status,
				updateInterval: interval, statusCode: response.statusCode
			)
		default:
			throw GitLabAPIError.unexpectedStatus(response.statusCode)
		}
	}

	/// `POST /api/v4/jobs/:id/artifacts`：上傳一份已打包好的產物。
	///
	/// 請求形狀照 runner 端（gitlab-runner v16.2 `network/gitlab.go` 的 `UploadRawArtifacts`）：
	/// `JOB-TOKEN` 標頭認證，本體是 `multipart/form-data`、只有一個欄位 `file`（檔名取
	/// ``JobArtifact/uploadFilename``），`expire_in`／`artifact_format`／`artifact_type` 三者
	/// 放在查詢字串、空值整項不帶。
	///
	/// **必須在回報終態之前送**：站台只收執行中 job 的產物，終態寫入之後再送會得到 403。
	///
	/// 站台回的非 201 一律**不當成錯誤拋出**，由回傳值分類（見 ``ArtifactUploadResult``）——
	/// 那些都是協議的一部分，重不重送由呼叫端決定。拋出的只有連線層的錯。
	///
	/// - Parameters:
	///   - host: 站台位址。
	///   - jobID: job 識別碼。
	///   - jobToken: job 專屬 token。
	///   - artifact: 這份產物的宣告；取檔名與三個查詢參數。
	///   - archive: 已打包好的檔案內容。
	/// - Returns: 站台回應的分類。
	/// - Throws: 連線層的錯（`GitLabAPIError` 或傳輸層自己的錯）。
	public func uploadArtifact(
		host: String,
		jobID: Int,
		jobToken: String,
		artifact: JobArtifact,
		archive: Data
	) async throws -> ArtifactUploadResult {
		let boundary: String = "labcontroller-\(UUID().uuidString)"
		let query: String = Self.artifactQuery(of: artifact)
		let response: HTTPResponse = try await send(
			method: "POST",
			host: host,
			path: query.isEmpty ? "jobs/\(jobID)/artifacts" : "jobs/\(jobID)/artifacts?\(query)",
			headers: [
				"Content-Type": "multipart/form-data; boundary=\(boundary)",
				"JOB-TOKEN": jobToken
			],
			body: Self.multipartBody(file: archive, filename: artifact.uploadFilename, boundary: boundary),
			timeout: Self.artifactUploadTimeout
		)
		switch response.statusCode {
		case 201:
			return .uploaded
		case 307:
			return .redirected(location: response.headerValue("Location"))
		case 403:
			return .forbidden
		case 413:
			return .tooLarge
		case 503:
			return .serviceUnavailable
		default:
			return .failed(statusCode: response.statusCode)
		}
	}

	/// 從解碼錯誤取出「解不開的位置」，只回鍵名路徑。
	///
	/// **不碰任何值**：這個字串會被寫進 log，而 body 裡有 job token 與變數值。
	static func codingPath(of error: any Error) -> String {
		guard let error = error as? DecodingError else { return "" }
		let path: [any CodingKey]
		switch error {
		case let .typeMismatch(_, context), let .valueNotFound(_, context):
			path = context.codingPath
		case let .keyNotFound(key, context):
			path = context.codingPath + [key]
		case let .dataCorrupted(context):
			path = context.codingPath
		@unknown default:
			return ""
		}
		return path.map(\.stringValue).joined(separator: ".")
	}

	/// 從站台回的 `Range: 0-<n>` 取出下一段的起始位移。
	///
	/// 站台的 `n`＝已寫入的總 byte 數（開區間端點），直接就是下一段的起始位移；
	/// 與送出端的閉區間端點不同，換算在此收斂、不外流給呼叫端。
	static func nextOffset(from range: String?) -> Int? {
		guard let range, let dash: String.Index = range.lastIndex(of: "-") else {
			return nil
		}
		return Int(range[range.index(after: dash)...])
	}

	/// 產物上傳的查詢字串；鍵依字母序、空值整項省略，值逐字元百分比編碼。
	///
	/// 只放行 URL 的非保留字元、其餘一律編碼：`expire_in` 是 CI 檔原文（例如 `1 week`），
	/// 而 `+` 在查詢字串裡會被站台讀成空白——只編碼一部分字元，`1+week` 這類值送過去就變了。
	internal static func artifactQuery(of artifact: JobArtifact) -> String {
		let pairs: [(String, String)] = [
			("artifact_format", artifact.artifactFormat),
			("artifact_type", artifact.artifactType),
			("expire_in", artifact.expireIn)
		]
		return pairs
			.filter { !$0.1.isEmpty }
			.map { "\($0.0)=\(percentEncoded($0.1))" }
			.joined(separator: "&")
	}

	/// 產物上傳的 `multipart/form-data` 本體：唯一一個欄位 `file`。
	///
	/// 檔名裡的反斜線與雙引號照 multipart 慣例跳脫；換行字元換成 `_`——檔名來自 payload，
	/// 讓它帶著換行進到欄位標頭，等於讓 payload 決定請求本體多出哪幾行標頭。
	internal static func multipartBody(file: Data, filename: String, boundary: String) -> Data {
		// 逐 Unicode scalar 處理、不走字串替換：Swift 把 `\r\n` 當成一個字元，以字元為單位替換
		// `\n` 時碰不到它，換行就原樣留在標頭裡。
		var escaped: String = ""
		for scalar in filename.unicodeScalars {
			switch scalar {
			case "\\":
				escaped += "\\\\"
			case "\"":
				escaped += "\\\""
			case "\r", "\n":
				escaped += "_"
			default:
				escaped.unicodeScalars.append(scalar)
			}
		}
		var body: Data = .init()
		body.append(Data("--\(boundary)\r\n".utf8))
		body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(escaped)\"\r\n".utf8))
		body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
		body.append(file)
		body.append(Data("\r\n--\(boundary)--\r\n".utf8))
		return body
	}

	/// 組出 `{host}/api/v4/{path}` 並送出；host 結尾多餘的斜線會先修剪。
	private func send(
		method: String,
		host: String,
		path: String,
		headers: [String: String],
		body: Data?,
		timeout: TimeInterval
	) async throws -> HTTPResponse {
		let base: String = host.hasSuffix("/") ? .init(host.dropLast()) : host
		guard let url: URL = .init(string: "\(base)/api/v4/\(path)"), url.scheme != nil else {
			throw GitLabAPIError.invalidURL(GitLabAPIError.safeLocation(of: host))
		}
		let request: HTTPRequest = .init(
			method: method,
			url: url,
			headers: headers,
			body: body,
			timeout: timeout
		)
		return try await transport.send(request)
	}

	/// 把字串百分比編碼成查詢字串的值；只留 RFC 3986 的非保留字元（ASCII 英數與 `-._~`）。
	private static func percentEncoded(_ value: String) -> String {
		var encoded: String = ""
		for byte in value.utf8 {
			let scalar: Unicode.Scalar = .init(byte)
			let isUnreserved: Bool = ("A" ... "Z").contains(scalar) || ("a" ... "z").contains(scalar)
				|| ("0" ... "9").contains(scalar) || "-._~".unicodeScalars.contains(scalar)
			encoded += isUnreserved ? String(scalar) : String(format: "%%%02X", byte)
		}
		return encoded
	}
}

/// `POST /api/v4/jobs/request` 的請求本體。
///
/// `last_update` 必須在 body——Workhorse 由此判斷要不要 hold 住連線做 long-poll。
private struct JobRequestPayload: Encodable {

	/// runner 認證 token。
	let token: String

	/// 上一輪拿到的游標；nil 時整鍵省略。
	let lastUpdate: String?

	/// runner 自述與能力宣告。
	let info: RunnerInfo

	/// 對應站台端欄位名（snake_case）。
	private enum CodingKeys: String, CodingKey {
		case token
		case lastUpdate = "last_update"
		case info
	}
}

/// `PUT /api/v4/jobs/:id` 的請求本體；nil 欄位整鍵省略。
private struct JobUpdatePayload: Encodable {

	/// job 專屬 token。
	let token: String

	/// 目標狀態。
	let state: String

	/// 失敗原因；非失敗時為 nil。
	let failureReason: String?

	/// script 的結束碼；未知時為 nil。
	let exitCode: Int?

	/// 對應站台端欄位名（snake_case）。
	private enum CodingKeys: String, CodingKey {
		case token
		case state
		case failureReason = "failure_reason"
		case exitCode = "exit_code"
	}
}
