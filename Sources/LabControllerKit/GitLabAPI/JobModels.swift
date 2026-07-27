//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// job 的環境變數；GitLab 把觸發脈絡（專案路徑、pipeline 來源、commit sha 等）都放這裡。
public struct JobVariable: Decodable, Sendable, Equatable {

    /// 變數名稱，例如 `CI_PROJECT_PATH`。
    public let key: String

    /// 變數值。
    public let value: String

    /// 是否為遮蔽變數；遮蔽者不得寫進 log。
    public let masked: Bool

    /// 是否以檔案形式提供給 job。
    public let file: Bool

    /// 以顯式欄位建立（測試用；正式路徑一律由回應解碼而來）。
    public init(key: String, value: String, masked: Bool = false, file: Bool = false) {
        self.key = key
        self.value = value
        self.masked = masked
        self.file = file
    }

    /// 解碼；`masked`／`file` 缺席時視為 false。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.value = try container.decode(String.self, forKey: .value)
        self.masked = try container.decodeIfPresent(Bool.self, forKey: .masked) ?? false
        self.file = try container.decodeIfPresent(Bool.self, forKey: .file) ?? false
    }

    /// 對應站台端欄位名。
    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case masked
        case file
    }
}

/// job 的一個執行步驟；本片只保留形狀，實際執行由後續切片承接。
public struct JobStep: Decodable, Sendable, Equatable {

    /// 步驟名稱，例如 `script`、`after_script`。
    public let name: String

    /// 該步驟要跑的指令列。
    public let script: [String]

    /// 失敗是否可容忍。
    public let allowFailure: Bool

    /// 以顯式欄位建立（測試用）。
    public init(name: String, script: [String], allowFailure: Bool = false) {
        self.name = name
        self.script = script
        self.allowFailure = allowFailure
    }

    /// 解碼；`script` 缺席視為空、`allow_failure` 缺席視為 false。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.script = try container.decodeIfPresent([String].self, forKey: .script) ?? []
        self.allowFailure = try container.decodeIfPresent(Bool.self, forKey: .allowFailure) ?? false
    }

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case name
        case script
        case allowFailure = "allow_failure"
    }
}

/// job 對應的 git 座標；供後續切片在執行沙箱內取出正確的程式碼版本。
public struct GitInfo: Decodable, Sendable, Equatable {

    /// 倉庫網址。
    public let repoURL: String

    /// 分支或 tag 名稱。
    public let ref: String

    /// 目標 commit sha。
    public let sha: String

    /// 以顯式欄位建立（測試用）。
    public init(repoURL: String, ref: String, sha: String) {
        self.repoURL = repoURL
        self.ref = ref
        self.sha = sha
    }

    /// 解碼；任一欄位缺席以空字串補。
    ///
    /// 刻意寬鬆：`git_info` 只要少一個鍵就整包 throw 的話，會讓「站台已指派給我們的
    /// job」被當成解碼失敗丟棄——job 於站台端仍掛在 running 直到逾時，比欄位不全糟得多。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.repoURL = try container.decodeIfPresent(String.self, forKey: .repoURL) ?? ""
        self.ref = try container.decodeIfPresent(String.self, forKey: .ref) ?? ""
        self.sha = try container.decodeIfPresent(String.self, forKey: .sha) ?? ""
    }

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case repoURL = "repo_url"
        case ref
        case sha
    }
}

/// `POST /api/v4/jobs/request` 回 201 時的 job 內容。
///
/// 刻意寬鬆解碼：站台端還會回 `artifacts`／`cache`／`services`／`job_info` 等欄位，
/// 本片不實作對應行為、解碼時一律忽略（未知欄位不致失敗）。欄位形狀待對凍齡站台
/// 實測後錄成 fixture 校準。
public struct JobResponse: Decodable, Sendable, Equatable {

    /// job 識別碼；trace 回寫與狀態回報都用它組路徑。
    public let id: Int

    /// 此 job 專屬的短命 token；trace／狀態回報用它認證，與 runner 認證 token 不同。
    public let token: String

    /// job 環境變數。
    public let variables: [JobVariable]

    /// job 執行步驟。
    public let steps: [JobStep]

    /// git 座標；站台端未提供時為 nil。
    public let gitInfo: GitInfo?

    /// 以顯式欄位建立（測試用）。
    public init(
        id: Int,
        token: String,
        variables: [JobVariable] = [],
        steps: [JobStep] = [],
        gitInfo: GitInfo? = nil
    ) {
        self.id = id
        self.token = token
        self.variables = variables
        self.steps = steps
        self.gitInfo = gitInfo
    }

    /// 解碼；集合類欄位缺席一律視為空，不因此判定回應無效。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.token = try container.decode(String.self, forKey: .token)
        self.variables = try container.decodeIfPresent([JobVariable].self, forKey: .variables) ?? []
        self.steps = try container.decodeIfPresent([JobStep].self, forKey: .steps) ?? []
        self.gitInfo = try container.decodeIfPresent(GitInfo.self, forKey: .gitInfo)
    }

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case id
        case token
        case variables
        case steps
        case gitInfo = "git_info"
    }
}

/// 一次領 job 的結果：拿到 job（201）或此刻無 job（204）。
public enum JobRequestOutcome: Sendable, Equatable {

    /// 站台端指派了一個 job。
    case assigned(JobResponse)

    /// 此刻沒有可領的 job；屬正常路徑、非錯誤。
    case noJob
}

/// 領 job 的完整結果：結果本身，加上要回帶給站台的游標。
public struct JobRequestResult: Sendable, Equatable {

    /// 這次領到什麼。
    public let outcome: JobRequestOutcome

    /// 下次 `jobs/request` 要帶的游標，**已與上一輪的值合併**、可直接沿用。
    ///
    /// 站台只在 **204 分支**發 `X-GitLab-Last-Update`（`lib/api/ci/runner.rb`
    /// 的 201 分支不發）。因此「沒收到就沿用舊值」是正確語義；若照「每次都覆寫」
    /// 處理，領到 job 的那一輪就會把游標清成 nil、long-poll 從此失效。
    /// 合併在協議層做掉，呼叫端直接存這個值即可。
    public let lastUpdate: String?

    /// 以顯式欄位建立。
    public init(outcome: JobRequestOutcome, lastUpdate: String?) {
        self.outcome = outcome
        self.lastUpdate = lastUpdate
    }
}

/// trace 回寫後站台的回覆。
public struct TraceAck: Sendable, Equatable {

    /// 站台回報的 job 狀態；值為 `canceled` 時代表此 job 已被取消、應停止執行。
    ///
    /// 何時會有值（16.2）：①trace 的**成功**路徑（`runner.rb` 唯一一處明寫）；
    /// ②**兩支端點**的 `job_forbidden!` 403——`lib/api/ci/helpers/runner.rb` 的
    /// `authenticate_job!` 在 job 非 running 時先 `header 'Job-Status'` 再
    /// `forbidden!`。其餘 403（token 失效、`trace_size_exceeded`）**不帶**此標頭，
    /// 故停止判準以 `isAborted`（狀態碼為主）為準、別只看這個欄位。
    public let jobStatus: String?

    /// 這次回寫的 HTTP 狀態碼；nil 代表沒發出請求（空 chunk）。
    public let statusCode: Int?

    /// 下一段 trace 應從哪個 byte 位移開始送。
    ///
    /// **端點語義與送出端相反、務必別直接沿用**：送出時 `Content-Range` 是
    /// **閉區間**（`start-(start+count-1)`）；站台回的 `Range: 0-<n>` 其中 `n`
    /// 是**已寫入的總 byte 數**（開區間端點）＝下一段的起始位移。換算收在協議層、
    /// 這裡直接給可用的位移值，避免呼叫端 ±1。
    ///
    /// nil＝站台沒告知。成功路徑可自行以 `start + count` 推進；但
    /// `needsResync` 為 true 又拿不到位移時**無從得知該從哪裡續傳**，應視為
    /// 不可恢復、停止此 job 的回寫。
    public let nextOffset: Int?

    /// 站台要求重新同步（416）：先前送出的位移與站台實際收到的對不上，
    /// 必須改從 `nextOffset` 重送。
    public let needsResync: Bool

    /// 站台建議的下次回寫間隔（`X-GitLab-Trace-Update-Interval`，秒）。
    public let updateInterval: TimeInterval?

    /// 以顯式欄位建立。
    public init(
        jobStatus: String? = nil,
        nextOffset: Int? = nil,
        needsResync: Bool = false,
        updateInterval: TimeInterval? = nil,
        statusCode: Int? = nil
    ) {
        self.jobStatus = jobStatus
        self.nextOffset = nextOffset
        self.needsResync = needsResync
        self.updateInterval = updateInterval
        self.statusCode = statusCode
    }

    /// 站台是否已把此 job 標成取消。
    ///
    /// 16.2 的狀態集合不含 `canceling`、只會回小寫 `canceled`。站台升上 17.x 後
    /// `canceling`（要求取消）與 `canceled`（已中止）是兩態，屆時此判定需拆開。
    public var isCanceled: Bool {
        jobStatus?.lowercased() == "canceled"
    }

    /// 是否應**立即停止**這個 job 的執行與回寫。
    ///
    /// 涵蓋兩種來源：
    /// - **403**——job 已非 running（取消／已結束）、job token 失效，或
    ///   `trace_size_exceeded`（站台會直接 `build.drop`）。其中**只有 `job_forbidden!`
    ///   那條（job 非 running）會帶 `Job-Status`**，token 類與 trace 超限類不帶，
    ///   所以**狀態碼才是主判準、標頭為輔**。若把它當成普通 ack，log 會持續灌進
    ///   黑洞、到最後回報終態才炸。
    /// - `Job-Status` 為 `canceled` / `failed`（對齊 runner 的 `IsFailed()`）。
    public var isAborted: Bool {
        if statusCode == 403 {
            return true
        }
        guard let status: String = jobStatus?.lowercased() else {
            return false
        }
        return status == "canceled" || status == "failed"
    }
}

/// 回報 job 狀態後站台的回覆。
public struct JobUpdateAck: Sendable, Equatable {

    /// 狀態是否已真正寫入站台。
    ///
    /// **202 不等於成功**：`Ci::UpdateBuildStateService` 回 202 的意思是「trace 尚未
    /// 落地、狀態還沒寫入，等 `updateInterval` 後重送」（runner 端對應
    /// `UpdateAcceptedButNotCompleted`）。把 202 當完成會讓 job 一直掛在 running、
    /// 直到站台的 accept timeout 才被判死，CI 顯示假完成／假失敗。
    ///
    /// ⚠️ **false 有兩種意思**：202（該重送）與 403（該停止）皆為 false。重送前
    /// **必先檢查 `isAborted`**，否則對已取消的 job 會無限重試。
    public let isCompleted: Bool

    /// 站台回報的 job 狀態。
    ///
    /// **keepalive 也偵測得到取消**：job 被取消後 `authenticate_job!` 會走
    /// `job_forbidden!`——先 `header 'Job-Status'` 再回 403。對「沒有新 log 可送的
    /// 安靜 job」而言，這條 keepalive 403 正是取消唯一會浮現的地方。
    /// 成功路徑（200／202）在 16.2 則不帶此標頭。
    public let jobStatus: String?

    /// 這次回報的 HTTP 狀態碼。
    public let statusCode: Int?

    /// 站台建議的重送間隔（`X-GitLab-Trace-Update-Interval`，秒）。
    public let updateInterval: TimeInterval?

    /// 以顯式欄位建立。
    public init(
        isCompleted: Bool,
        jobStatus: String? = nil,
        updateInterval: TimeInterval? = nil,
        statusCode: Int? = nil
    ) {
        self.isCompleted = isCompleted
        self.jobStatus = jobStatus
        self.updateInterval = updateInterval
        self.statusCode = statusCode
    }

    /// 站台是否已把此 job 標成取消。
    public var isCanceled: Bool {
        jobStatus?.lowercased() == "canceled"
    }

    /// 是否應**立即停止**這個 job。
    ///
    /// 與 `TraceAck.isAborted` 同一套判準（兩支端點對稱）：403 代表 job 已非
    /// running（取消／已結束）或 token 失效——取消造成的 403 帶 `Job-Status`、
    /// token 造成的不帶，故**以狀態碼為主判準、標頭為輔**。
    public var isAborted: Bool {
        if statusCode == 403 {
            return true
        }
        guard let status: String = jobStatus?.lowercased() else {
            return false
        }
        return status == "canceled" || status == "failed"
    }
}

/// 向站台宣告本 runner 支援哪些能力。
///
/// ⚠️ **宣告不足會讓 job 被判死、不是被跳過**：站台在指派前檢查
/// `supported_runner?(info.features)`，不符即 `build.drop!(runner_unsupported)`。
/// 例如未宣告 `refspecs` 時，**merge request pipeline 的 job 一被領走就變 failed**。
/// 反過來宣告了卻沒實作，則是領到後執行失敗。兩邊都不能亂填、必須跟著執行端的
/// 真實能力走。
public struct RunnerFeatures: Encodable, Sendable, Equatable {

    /// 支援以 refspecs 取得程式碼（merge request pipeline 需要）。
    public var refspecs: Bool

    /// 支援多段 build step（`release:` 等需要）。
    public var multiBuildSteps: Bool

    /// 支援回報 script 的結束碼（`allow_failure:exit_codes` 需要）。
    public var returnExitCode: Bool

    /// 支援一次上傳多個 artifacts（`artifacts:reports` 需要）。
    public var uploadMultipleArtifacts: Bool

    /// 支援 `artifacts:exclude`。
    public var artifactsExclude: Bool

    /// 支援 `cache:fallback_keys`。
    public var fallbackCacheKeys: Bool

    /// 以顯式欄位建立；**預設全 false**。
    ///
    /// 對站台而言「全 false」與「不送 features」等價（其判定是
    /// `features&.dig(name)`）——false 是沉默、不是宣告。宣告 true 卻做不到，等於
    /// 把站台本可自行排程的問題換成一次真實的 CI 失敗，嚴格更糟。
    public init(
        refspecs: Bool = false,
        multiBuildSteps: Bool = false,
        returnExitCode: Bool = false,
        uploadMultipleArtifacts: Bool = false,
        artifactsExclude: Bool = false,
        fallbackCacheKeys: Bool = false
    ) {
        self.refspecs = refspecs
        self.multiBuildSteps = multiBuildSteps
        self.returnExitCode = returnExitCode
        self.uploadMultipleArtifacts = uploadMultipleArtifacts
        self.artifactsExclude = artifactsExclude
        self.fallbackCacheKeys = fallbackCacheKeys
    }

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case refspecs
        case multiBuildSteps = "multi_build_steps"
        case returnExitCode = "return_exit_code"
        case uploadMultipleArtifacts = "upload_multiple_artifacts"
        case artifactsExclude = "artifacts_exclude"
        case fallbackCacheKeys = "fallback_cache_keys"
    }
}

/// 領 job 時一併送出的 runner 自述。
public struct RunnerInfo: Encodable, Sendable, Equatable {

    /// runner 實作名稱。
    public var name: String

    /// runner 版本。
    public var version: String

    /// 執行器種類。
    public var executor: String

    /// 支援能力宣告。
    public var features: RunnerFeatures

    /// 以顯式欄位建立。
    public init(
        name: String = "lab-controller",
        version: String = "0.1.0",
        executor: String = "custom",
        features: RunnerFeatures = .init()
    ) {
        self.name = name
        self.version = version
        self.executor = executor
        self.features = features
    }
}

/// 回報 job 終態時的狀態值。
public enum JobState: String, Sendable {

    /// 執行中。
    case running

    /// 成功結束。
    case success

    /// 失敗結束。
    case failed
}

/// job 失敗的原因分類；決定站台端要不要重試。
///
/// 對齊 custom executor 的 exit code 語義：程式錯不重試、環境錯可重試。
public enum JobFailureReason: String, Sendable {

    /// script 回非 0；屬程式錯、不重試。
    case scriptFailure = "script_failure"

    /// 執行環境起不來（VM／keychain／clone 失敗）；屬環境錯、可重試。
    case runnerSystemFailure = "runner_system_failure"

    /// 執行逾時；比照環境錯處理。
    case jobExecutionTimeout = "job_execution_timeout"
}
