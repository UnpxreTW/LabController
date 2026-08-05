//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// `POST /api/v4/jobs/request` 回 201 時的 job 內容。
///
/// 刻意寬鬆解碼：站台端還會回 `job_info`／`credentials`／`hooks` 等本片不消化的欄位，
/// 解碼時一律忽略（未知欄位不致失敗）。
///
/// **不消化 ≠ 可以不看**：`image`／`services`／`artifacts`／`cache`／`dependencies`
/// 五個欄位雖然沒有對應實作，仍必須解出「有沒有宣告」——CI 檔要求了而 runner 默默不做，
/// job 會綠得毫無破綻。判定收不收在 `JobAdmission`，本型別只負責把宣告如實帶出來。
///
/// **解碼的硬不變式：除了 `id` 與 `token`，沒有任何欄位可以害整包解不出來。** 整包解碼
/// 失敗在呼叫端等同「這個 job 從未存在」——站台早已把它標成 running，卻永遠收不到任何
/// 回報，一路掛到逾時，而且 log 上只有一行「body 解不開」。所以其餘欄位一律改成：形狀
/// 不符預期就把鍵名記進 `unreadableFields`、其餘部分照常解，交由 `JobAdmission` 擋下並
/// 在 trace 上明說。**協議漂移要讓 job 紅得看得見，不是讓 job 消失。**
public struct JobResponse: Decodable, Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// job 識別碼；trace 回寫與狀態回報都用它組路徑。
    public let id: Int

    /// 此 job 專屬的短命 token；trace／狀態回報用它認證，與 runner 認證 token 不同。
    ///
    /// ⚠️ **憑證**：本型別的 `description`／`customMirror` 刻意不含它，變數值同理。
    public let token: String

    /// job 環境變數。
    public let variables: [JobVariable]

    /// job 執行步驟。
    public let steps: [JobStep]

    /// git 座標；站台端未提供時為 nil。
    public let gitInfo: GitInfo?

    /// 站台對本次執行的指示（目前只有逾時）；未提供時為 nil。
    public let runnerInfo: JobRunnerInfo?

    /// CI 檔指定的 container image 名稱。
    ///
    /// 判準是「CI 檔有沒有要求 image」而不是「名字寫了沒」：payload 送了 `image` 物件卻
    /// 沒帶 `name`（或帶空字串）時，這裡回空字串而非 nil——回 nil 會讓收件判定當成沒宣告，
    /// 於是一個要求容器的 job 被當普通 job 跑完回綠。
    ///
    /// **nil 有兩種意思**：欄位缺席／為 null（真的沒宣告），或該欄位形狀讀不懂——後者
    /// **必定同時出現在 `unreadableFields`**。因此「`imageName == nil` ⇒ 沒要求容器」
    /// 這個推論只有在 `unreadableFields` 為空時才成立。
    public let imageName: String?

    /// CI 檔宣告的 service 數量。
    public let serviceCount: Int

    /// CI 檔宣告的產物上傳項目數量。
    public let artifactCount: Int

    /// CI 檔宣告的快取項目數量。
    public let cacheCount: Int

    /// 本 job 的全部上游；**含沒有產物者**，判有無產物走 `carriesArtifacts`。
    public let dependencies: [JobDependency]

    /// payload 裡有、但形狀不是本片認得的欄位名（站台端原始鍵名）。
    ///
    /// **非空 ≠ 沒宣告**：這代表協議已經漂移（例如 `cache` 由陣列改成物件），該欄位到底
    /// 宣告了什麼無從得知，因此**同一 payload 的其餘判定也不可信**。`JobAdmission` 一律
    /// 把它當成擋路的缺口，讓 job 明確紅在 trace 上、附上是哪個欄位讀不懂。
    public let unreadableFields: [String]

    /// 以顯式欄位建立（測試用）。
    public init(
        id: Int,
        token: String,
        variables: [JobVariable] = [],
        steps: [JobStep] = [],
        gitInfo: GitInfo? = nil,
        runnerInfo: JobRunnerInfo? = nil,
        imageName: String? = nil,
        serviceCount: Int = 0,
        artifactCount: Int = 0,
        cacheCount: Int = 0,
        dependencies: [JobDependency] = [],
        unreadableFields: [String] = []
    ) {
        self.id = id
        self.token = token
        self.variables = variables
        self.steps = steps
        self.gitInfo = gitInfo
        self.runnerInfo = runnerInfo
        self.imageName = imageName
        self.serviceCount = serviceCount
        self.artifactCount = artifactCount
        self.cacheCount = cacheCount
        self.dependencies = dependencies
        self.unreadableFields = unreadableFields
    }

    /// 印出來只給形狀；`token` 與變數值不進任何輸出。
    public var description: String {
        "JobResponse(id: \(id), steps: \(steps.count), variables: \(variables.count))"
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
                "id": id,
                "steps": steps.count,
                "variables": variables.count,
                "imageName": imageName ?? "nil",
                "serviceCount": serviceCount,
                "artifactCount": artifactCount,
                "cacheCount": cacheCount,
                "dependencies": dependencies.count,
                "unreadableFields": unreadableFields,
            ],
            displayStyle: .struct
        )
    }

    /// 解碼；集合類欄位缺席一律視為空，形狀不符則記進 `unreadableFields` 而非拋出。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        // 只有這兩個欄位缺了就真的無事可做：沒有 id 無從回報、沒有 token 無從認證。
        self.id = try container.decode(Int.self, forKey: .id)
        self.token = try container.decode(String.self, forKey: .token)
        var unreadable: [String] = []
        self.variables = Self.optional([JobVariable].self, in: container, forKey: .variables, into: &unreadable) ?? []
        self.steps = Self.optional([JobStep].self, in: container, forKey: .steps, into: &unreadable) ?? []
        self.gitInfo = Self.optional(GitInfo.self, in: container, forKey: .gitInfo, into: &unreadable)
        self.runnerInfo = Self.optional(JobRunnerInfo.self, in: container, forKey: .runnerInfo, into: &unreadable)
        self.imageName = Self.imageName(in: container, into: &unreadable)
        self.serviceCount = Self.count(in: container, forKey: .services, into: &unreadable)
        self.artifactCount = Self.count(in: container, forKey: .artifacts, into: &unreadable)
        self.cacheCount = Self.count(in: container, forKey: .cache, into: &unreadable)
        self.dependencies = Self.optional(
            [JobDependency].self,
            in: container,
            forKey: .dependencies,
            into: &unreadable
        ) ?? []
        // `when` 對映不到不是「少一個小欄位」：回落值會讓步驟跑在錯的結果分支上，與形狀
        // 漂移同級，因此走同一條通道擋下。一個 job 只記一次，別讓 100 個步驟刷出 100 行。
        if self.steps.contains(where: { $0.unrecognisedRunCondition != nil }) {
            unreadable.append("steps[].when")
        }
        // 站台說某個上游有產物、我們卻讀不出檔名：形狀跟預期不一樣，不可以就這樣算了。
        if self.dependencies.contains(where: \.hasUnreadableArtifactsFilename) {
            unreadable.append("dependencies[].artifacts_file.filename")
        }
        self.unreadableFields = unreadable
    }

    /// 解一個可缺席的欄位；形狀不符時**不拋**，改把鍵名記進 `unreadable` 並回 nil。
    private static func optional<Value: Decodable>(
        _ type: Value.Type,
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        into unreadable: inout [String]
    ) -> Value? {
        // 走 do/catch 而非 `try?`：`decodeIfPresent` 本來就回 optional，`try?` 會把
        // 「解不出來」與「欄位缺席」壓成同一個 nil，於是形狀漂移悄悄變成「沒宣告」。
        do {
            return try container.decodeIfPresent(type, forKey: key)
        } catch {
            unreadable.append(key.stringValue)
            return nil
        }
    }

    /// 數出某個陣列欄位有幾筆，不解其內容。
    ///
    /// 本片只需要知道「有沒有宣告」。為了計數而把站台的欄位形狀抄成一組型別，等於替
    /// 還沒實作的能力先綁死一份 schema——那份 schema 沒有任何測試會驗它，卻會隨站台
    /// 版本慢慢腐爛，等真的要實作時反而得先分辨哪些欄位是當年抄錯的。
    ///
    /// 鍵不存在或為 null 都算 0 筆；鍵在、非 null 卻不是陣列則記進 `unreadable`——那代表
    /// 協議變了，要顯眼地失敗，但**失敗的方式是讓這個 job 紅、不是讓整包 payload 消失**。
    private static func count(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        into unreadable: inout [String]
    ) -> Int {
        guard container.contains(key) else { return 0 }
        guard let isNull: Bool = try? container.decodeNil(forKey: key) else {
            unreadable.append(key.stringValue)
            return 0
        }
        guard !isNull else { return 0 }
        guard let nested: UnkeyedDecodingContainer = try? container.nestedUnkeyedContainer(forKey: key) else {
            unreadable.append(key.stringValue)
            return 0
        }
        // 數不出筆數就不能當「沒宣告」——那是該拒不拒的方向。實務上 JSONDecoder 一定給得出
        // 來，但這個 `??` 的預設值決定的是「不確定時往哪邊倒」，倒向 0 等於默默放行。
        guard let count: Int = nested.count else {
            unreadable.append(key.stringValue)
            return 0
        }
        return count
    }

    /// 取出 `image.name`；job 未指定 image 時站台把該欄位送成 null。
    ///
    /// **`image` 物件讀得懂就一定回非 nil**：名稱缺席或為空時回空字串，讓收件判定仍看得到
    /// 「這個 job 要求了容器」。回 nil 代表欄位缺席／為 null，或形狀讀不懂（後者同時記進
    /// `unreadable`）。
    private static func imageName(
        in container: KeyedDecodingContainer<CodingKeys>,
        into unreadable: inout [String]
    ) -> String? {
        guard container.contains(.image) else { return nil }
        guard let isNull: Bool = try? container.decodeNil(forKey: .image) else {
            unreadable.append(CodingKeys.image.stringValue)
            return nil
        }
        guard !isNull else { return nil }
        // 形狀讀不懂時只記 unreadable、不另外回一個假的名字：`unreadableFields` 已足以擋下
        // 這個 job，再補一條「image 名稱為（未具名）」只會在 trace 上多一行誤導——名字其實
        // 就在 payload 裡，只是我們讀不出它的形狀。
        guard let image: KeyedDecodingContainer<ImageCodingKeys> = try? container.nestedContainer(
            keyedBy: ImageCodingKeys.self,
            forKey: .image
        ) else {
            unreadable.append(CodingKeys.image.stringValue)
            return nil
        }
        do {
            return try image.decodeIfPresent(String.self, forKey: .name) ?? ""
        } catch {
            unreadable.append(CodingKeys.image.stringValue)
            return nil
        }
    }

    /// `image` 物件內本片唯一會讀的欄位。
    private enum ImageCodingKeys: String, CodingKey {
        case name
    }

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case id
        case token
        case variables
        case steps
        case gitInfo = "git_info"
        case runnerInfo = "runner_info"
        case image
        case services
        case artifacts
        case cache
        case dependencies
    }
}
