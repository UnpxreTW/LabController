//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// job 的一個上游相依；對應協議 `dependencies[]`。
///
/// ⚠️ **「有相依」不等於「有產物要下載」**：站台送的是該 job 的 *全部* 上游
/// （`job.all_dependencies`，前面每個 stage 的 job 都在內），而 `artifacts_file`
/// 只在該上游**真的存了產物**時才出現（16.2 `Entities::Ci::JobRequest::Dependency`
/// 對該欄掛 `if: available_artifacts?`）。拿「陣列非空」當「需要下載產物」，會讓每一個
/// 多 stage 的 job 都被誤判成本 executor 做不到——判準必須是 `carriesArtifacts`。
public struct JobDependency: Decodable, Sendable, Equatable {

    /// 上游 job 的識別碼。
    public let identifier: Int

    /// 上游 job 的名稱；寫進 trace 時用它指名是哪一個。
    public let name: String

    /// 上游 job 的產物檔；nil 代表該 job 沒有產物可下載。
    public let artifactsFile: DependencyArtifactsFile?

    /// 以顯式欄位建立（測試用；正式路徑一律由回應解碼而來）。
    public init(identifier: Int, name: String, artifactsFile: DependencyArtifactsFile? = nil) {
        self.identifier = identifier
        self.name = name
        self.artifactsFile = artifactsFile
    }

    /// 解碼；`id`／`name` 缺席以 0 與空字串補，不因此判定整包無效。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.identifier = try container.decodeIfPresent(Int.self, forKey: .identifier) ?? 0
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.artifactsFile = try container.decodeIfPresent(DependencyArtifactsFile.self, forKey: .artifactsFile)
    }

    /// 這個相依是否真的帶著要下載的產物。
    ///
    /// 空檔名視同沒有產物：站台端有產物才給這個物件，但檔名為空的話也無從下載。
    public var carriesArtifacts: Bool {
        guard let artifactsFile else { return false }
        return !artifactsFile.filename.isEmpty
    }

    /// 對應站台端欄位名（snake_case）。
    private enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case name
        case artifactsFile = "artifacts_file"
    }
}
