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

    /// 站台對本次執行的指示（目前只有逾時）；未提供時為 nil。
    public let runnerInfo: JobRunnerInfo?

    /// CI 檔指定的 container image 名稱；未指定時為 nil。
    public let imageName: String?

    /// CI 檔宣告的 service 數量。
    public let serviceCount: Int

    /// CI 檔宣告的產物上傳項目數量。
    public let artifactCount: Int

    /// CI 檔宣告的快取項目數量。
    public let cacheCount: Int

    /// 本 job 的全部上游；**含沒有產物者**，判有無產物走 `carriesArtifacts`。
    public let dependencies: [JobDependency]

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
        dependencies: [JobDependency] = []
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
    }

    /// 解碼；集合類欄位缺席一律視為空，不因此判定回應無效。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.token = try container.decode(String.self, forKey: .token)
        self.variables = try container.decodeIfPresent([JobVariable].self, forKey: .variables) ?? []
        self.steps = try container.decodeIfPresent([JobStep].self, forKey: .steps) ?? []
        self.gitInfo = try container.decodeIfPresent(GitInfo.self, forKey: .gitInfo)
        self.runnerInfo = try container.decodeIfPresent(JobRunnerInfo.self, forKey: .runnerInfo)
        self.imageName = try Self.imageName(in: container)
        self.serviceCount = try Self.count(in: container, forKey: .services)
        self.artifactCount = try Self.count(in: container, forKey: .artifacts)
        self.cacheCount = try Self.count(in: container, forKey: .cache)
        self.dependencies = try container.decodeIfPresent([JobDependency].self, forKey: .dependencies) ?? []
    }

    /// 數出某個陣列欄位有幾筆，不解其內容。
    ///
    /// 本片只需要知道「有沒有宣告」。為了計數而把站台的欄位形狀抄成一組型別，等於替
    /// 還沒實作的能力先綁死一份 schema——那份 schema 沒有任何測試會驗它，卻會隨站台
    /// 版本慢慢腐爛，等真的要實作時反而得先分辨哪些欄位是當年抄錯的。
    ///
    /// 鍵不存在或為 null 都算 0 筆；鍵在、非 null 卻不是陣列則照常拋——那代表協議變了，
    /// 該讓它顯眼地失敗。
    private static func count(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return 0 }
        let nested: UnkeyedDecodingContainer = try container.nestedUnkeyedContainer(forKey: key)
        return nested.count ?? 0
    }

    /// 取出 `image.name`；job 未指定 image 時站台把該欄位送成 null。
    private static func imageName(in container: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        guard container.contains(.image), try !container.decodeNil(forKey: .image) else { return nil }
        let image: KeyedDecodingContainer<ImageCodingKeys> = try container.nestedContainer(
            keyedBy: ImageCodingKeys.self,
            forKey: .image
        )
        return try image.decodeIfPresent(String.self, forKey: .name)
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
