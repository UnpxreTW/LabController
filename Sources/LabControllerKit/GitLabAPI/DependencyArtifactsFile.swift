//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 上游 job 存下的產物檔描述；對應協議 `dependencies[].artifacts_file`。
///
/// 站台只在該上游**真的有產物**時才送這個物件，所以「有沒有這一段」本身就是判準——
/// 詳見 `JobDependency.carriesArtifacts`。
public struct DependencyArtifactsFile: Decodable, Sendable, Equatable {

    /// 產物檔名。
    public let filename: String

    /// 產物大小（byte）。
    public let size: Int

    /// 以顯式欄位建立（測試用；正式路徑一律由回應解碼而來）。
    public init(filename: String, size: Int = 0) {
        self.filename = filename
        self.size = size
    }

    /// 解碼；兩欄缺席時分別以空字串與 0 補。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        self.size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }

    /// 對應站台端欄位名。
    private enum CodingKeys: String, CodingKey {
        case filename
        case size
    }
}
