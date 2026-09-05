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
    ///
    /// 站台送 null 時為空字串：GitLab CE 對未設分類標籤的專案，`CI_PROJECT_CLASSIFICATION_LABEL`
    /// 的值恆為 null（該設定屬付費版能力、社群版設不了），而那是每一個 job 都會收到的變數。
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

    /// 解碼；`value` 缺席或為 null 視為空字串，`masked`／`file` 缺席時視為 false。
    ///
    /// `value` 刻意不拋：站台一定會送出值為 null 的變數（見該屬性說明），把它當解碼失敗會
    /// 讓每一個 job 的變數都讀不出來。官方 runner 在同一個位置得到的也是字串的零值。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
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

/// 印出來只給名稱與旗標、不給值。
///
/// 一個變數是不是秘密，看的是站台有沒有標 `masked`——但**沒標的也未必能公開**（部署憑證
/// 靠設定紀律而非旗標的情況很常見）。預設反射會把每個 `value` 原樣吐出來，因此這裡一律
/// 不印值，不分是否 masked。
extension JobVariable: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// 只描述名稱與旗標。
    public var description: String {
        "JobVariable(key: \(key), masked: \(masked), file: \(file))"
    }

    /// 與 `description` 相同；debug 情境更需要這層保護，不是更不需要。
    public var debugDescription: String {
        description
    }

    /// `dump` 走 `Mirror`、繞過上面兩者，故一併收口。
    public var customMirror: Mirror {
        .init(self, children: ["key": key, "masked": masked, "file": file], displayStyle: .struct)
    }
}

/// job 對應的 git 座標；供後續切片在執行沙箱內取出正確的程式碼版本。
public struct GitInfo: Decodable, Sendable, Equatable {

    /// 倉庫網址。
    ///
    /// ⚠️ **可能內嵌憑證**：站台慣例會把 job token 放進 userinfo（`user:token@host/...`），
    /// 因此這個字串不可原樣印出或寫進 trace。本型別的 `description` 已把 userinfo 抹掉，
    /// 但要送去別的地方前請自己再確認一次。
    public let repoURL: String

    /// 分支或 tag 名稱。
    public let ref: String

    /// 目標 commit sha。
    public let sha: String

    /// 站台指定的取碼 refspec。
    ///
    /// 合併請求那類 pipeline 跑的不是分支頂端，而是站台另外算出來的一個 commit，它只掛在
    /// `refs/merge-requests/<n>/head` 這種一般 fetch 抓不到的 ref 下；站台因此改送一組
    /// refspec，要求照它給的抓。**本側把每一條當不透明字串原樣交給 `git`**——站台送什麼形狀
    /// 是站台的事，本側去猜只會在它換形狀時錯得無聲無息。缺席或空陣列＝一般 push 形，照
    /// ``ref`` 抓即可。
    public let refspecs: [String]

    /// 以顯式欄位建立（測試用）。
    public init(repoURL: String, ref: String, sha: String, refspecs: [String] = []) {
        self.repoURL = repoURL
        self.ref = ref
        self.sha = sha
        self.refspecs = refspecs
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
        self.refspecs = try container.decodeIfPresent([String].self, forKey: .refspecs) ?? []
    }

    /// 站台送了 `git_info`、但少了取碼所需的座標。
    ///
    /// 與寬鬆解碼分工：解碼刻意不拋（少一個鍵就丟掉整個 job 更糟），但「缺了什麼」必須有
    /// 人接手。缺 `repo_url` 或 `sha` 時 clone 根本做不到，留到執行階段才炸，錯誤訊息會跟
    /// 「站台沒給座標」完全連不起來。由 `JobResponse.unreadableFields` 承接、收件時擋下。
    public var hasIncompleteCoordinates: Bool {
        repoURL.isEmpty || sha.isEmpty
    }

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case repoURL = "repo_url"
        case ref
        case sha
        case refspecs
    }
}

/// 印出來的網址一律抹掉 userinfo。
extension GitInfo: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// 抹掉 userinfo 的網址加上 ref／sha，以及 refspec 條數。
    ///
    /// refspec 只印條數不印內容：一行敘述要保持有界，而「站台有沒有另外指定取碼路徑」這件事
    /// 條數就答得完；要看內容走 `dump`。
    public var description: String {
        "GitInfo(repo: \(Self.withoutUserInfo(repoURL)), ref: \(ref), sha: \(sha), refspecs: \(refspecs.count))"
    }

    /// 與 `description` 相同；debug 情境更需要這層保護，不是更不需要。
    public var debugDescription: String {
        description
    }

    /// `dump` 走 `Mirror`、繞過上面兩者，故一併收口。
    public var customMirror: Mirror {
        .init(
            self,
            children: [
                "repoURL": Self.withoutUserInfo(repoURL),
                "ref": ref,
                "sha": sha,
                "refspecs": refspecs,
            ],
            displayStyle: .struct
        )
    }

    /// 把 `scheme://user:secret@host/...` 的 userinfo 段換掉。
    ///
    /// 三個容易寫錯的地方，都刻意處理過：
    /// - **scheme 可以沒有**（`user:token@host/path` 是合法的 scp 式寫法）——只認
    ///   `://` 的話這種形狀會原樣印出憑證。
    /// - **只看 authority 段**（到第一個 `/`／`?`／`#` 為止）——`@` 出現在 path 裡是
    ///   正常的（`repo@v1.git`），照砍會把路徑吃掉。
    /// - **取 authority 內最後一個 `@`**——密碼未經 URL 編碼而含 `@` 時，取第一個會讓
    ///   密碼的後半截留在輸出裡。
    ///
    /// authority 內沒有 `@` 就沒有 userinfo，原樣回傳。
    private static func withoutUserInfo(_ url: String) -> String {
        let afterScheme: String.Index = schemeEnd(of: url) ?? url.startIndex
        let rest: Substring = url[afterScheme...]
        let authorityEnd: String.Index = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
            ?? rest.endIndex
        let authority: Substring = rest[..<authorityEnd]
        guard let at: String.Index = authority.lastIndex(of: "@") else { return url }
        return url[..<afterScheme] + "***@" + url[url.index(after: at)...]
    }

    /// 找出開頭那個 `scheme://` 的結束位置；開頭不是合法 scheme 就回 nil。
    ///
    /// 不能用「字串裡第一個 `://`」：未經 URL 編碼的密碼裡可以有 `://`，命中它會讓切點落
    /// 在憑證中間，後續的 authority 切法跟著全錯、最後把整串原樣印出去。scheme 依 RFC 3986
    /// 必須以字母開頭、其後只允許字母／數字／`+`／`-`／`.`。
    private static func schemeEnd(of url: String) -> String.Index? {
        let scheme: Substring = url.prefix { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
        guard let first: Character = scheme.first, first.isLetter else { return nil }
        guard url[scheme.endIndex...].hasPrefix("://") else { return nil }
        return url.index(scheme.endIndex, offsetBy: 3)
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

    /// runner 版本；預設為建置時由 git 標籤推導的值。
    public var version: String

    /// 執行器種類。
    public var executor: String

    /// 支援能力宣告。
    public var features: RunnerFeatures

    /// 以顯式欄位建立。
    public init(
        name: String = "lab-controller",
        version: String = LabControllerVersion.current,
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
