//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// job payload 裡的一項產物宣告；對應協議 `artifacts[]` 的一個元素。
///
/// 一個 CI 檔的 `artifacts:` 區塊在站台端會被拆成好幾項送來：`paths` 那一份是一項
/// （`artifact_type` 為 `archive`），每一種 `reports` 又各是一項。本型別只把宣告如實解出來，
/// 收不收由 `JobAdmission` 判。
///
/// 形狀依據：gitlab-runner v16.2 的 `common/network.go`（`Artifact`）與
/// `commands/helpers/artifacts_uploader.go`（上傳檔名）。
public struct JobArtifact: Decodable, Sendable, Equatable {

	// MARK: Public

	/// 上傳時的檔名：名稱的最後一段，加上打包格式對應的副檔名。
	///
	/// 名稱為空、只剩 `.` 或只有斜線時取 `default`；`raw` 與不認得的格式不加副檔名。除了只有
	/// 斜線的名稱（runner 端會得到 `/.zip`）之外與 runner 端同一套規則：站台依這個檔名決定下載時的
	/// 檔名，自己換一套命名，同一份產物在兩種 runner 上會下載成兩個名字。
	public var uploadFilename: String {
		let lastComponent: String = name.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
		let base: String = lastComponent.isEmpty || lastComponent == "." ? "default" : lastComponent
		switch artifactFormat {
		case "", "zip", "zipzstd":
			return base + ".zip"
		case "gzip":
			return base + ".gz"
		case "tarzstd":
			return base + ".tar.zst"
		default:
			return base
		}
	}

	/// 宣告的產物名稱；未宣告時為空字串。上傳時的檔名由它衍生（見 ``uploadFilename``）。
	public let name: String

	/// 是否連同未納入版本控制的檔案一起收。
	public let untracked: Bool

	/// 要收的路徑，相對於取回的程式碼目錄；可含 glob。
	public let paths: [String]

	/// 從 `paths` 收到的檔案中要排除的路徑。
	public let exclude: [String]

	/// 在什麼結果下才上傳；對應協議欄位 `when`。
	///
	/// 值域與步驟的 `when` 相同，判斷也相同：上傳時拿 job 是否已失敗去問
	/// ``JobStepWhen/shouldRun(afterFailure:)``。欄位缺席或為空字串時是 `.onSuccess`
	/// （runner 端同樣把空字串當成 `on_success`）；對映不到時也是 `.onSuccess`，
	/// 真正送來的字串留在 ``unrecognisedUploadCondition``——讀這個欄位前先確認那個是 nil。
	public let uploadCondition: JobStepWhen

	/// 站台送來、但本型別對映不到的 `when` 值；對映得到（含空字串）時為 nil。
	///
	/// 理由同 ``JobStep/unrecognisedRunCondition``：回落成 `on_success` 會讓產物在不該上傳的
	/// 結果下上傳、或在該上傳時不上傳，因此由 `JobResponse` 收進 `unreadableFields`。
	public let unrecognisedUploadCondition: String?

	/// 產物種類；`archive` 是 `paths` 那一份，其餘（`junit`、`codequality` 等）是 `reports`。
	/// 未宣告時為空字串，上傳時不帶、由站台套預設值。
	public let artifactType: String

	/// 打包格式（`zip`、`gzip`、`raw` 等）；未宣告時為空字串，打包時當成 `zip`。
	public let artifactFormat: String

	/// 保存期限，原樣轉給站台（例如 `1 week`）；未宣告時為空字串、上傳時不帶。
	public let expireIn: String

	/// 以顯式欄位建立（測試用；正式路徑一律由回應解碼而來）。
	public init(
		name: String = "",
		untracked: Bool = false,
		paths: [String] = [],
		exclude: [String] = [],
		uploadCondition: JobStepWhen = .onSuccess,
		unrecognisedUploadCondition: String? = nil,
		artifactType: String = "",
		artifactFormat: String = "",
		expireIn: String = ""
	) {
		self.name = name
		self.untracked = untracked
		self.paths = paths
		self.exclude = exclude
		self.uploadCondition = uploadCondition
		self.unrecognisedUploadCondition = unrecognisedUploadCondition
		self.artifactType = artifactType
		self.artifactFormat = artifactFormat
		self.expireIn = expireIn
	}

	/// 解碼；每個欄位缺席或為 null 都回落成空值，`when` 走「解成字串再對映」。
	///
	/// 欄位形狀不符（例如 `paths` 送成字串）時照常拋出，由 `JobResponse` 把整個 `artifacts`
	/// 記成讀不懂的欄位——一項宣告讀錯一半，比整項讀不懂更危險。
	public init(from decoder: any Decoder) throws {
		let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
		self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
		self.untracked = try container.decodeIfPresent(Bool.self, forKey: .untracked) ?? false
		self.paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
		self.exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
		let condition: String = try container.decodeIfPresent(String.self, forKey: .uploadCondition) ?? ""
		let mapped: JobStepWhen? = condition.isEmpty ? .onSuccess : JobStepWhen(rawValue: condition)
		self.uploadCondition = mapped ?? .onSuccess
		self.unrecognisedUploadCondition = mapped == nil ? condition : nil
		self.artifactType = try container.decodeIfPresent(String.self, forKey: .artifactType) ?? ""
		self.artifactFormat = try container.decodeIfPresent(String.self, forKey: .artifactFormat) ?? ""
		self.expireIn = try container.decodeIfPresent(String.self, forKey: .expireIn) ?? ""
	}

	// MARK: Private

	/// 對應站台端欄位名（snake_case）。
	private enum CodingKeys: String, CodingKey {
		case name
		case untracked
		case paths
		case exclude
		case uploadCondition = "when"
		case artifactType = "artifact_type"
		case artifactFormat = "artifact_format"
		case expireIn = "expire_in"
	}
}
