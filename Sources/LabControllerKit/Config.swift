//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// lab-controller 的執行組態；所有欄位皆於行程啟動時由 CLI 引數注入，缺欄一律回落預設值。
public struct Config: Codable, Sendable {

    /// 輪詢相關設定的巢狀容器。
    public struct Poll: Codable, Sendable {

        /// 兩次輪詢之間的間隔秒數；缺欄時回落 60。
        public var intervalSeconds: Int

        /// 以顯式間隔建立；預設 60 秒。
        public init(intervalSeconds: Int = 60) {
            self.intervalSeconds = intervalSeconds
        }

        /// 解碼缺 `intervalSeconds` 欄時回落預設 60。
        public init(from decoder: any Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            self.intervalSeconds = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 60
        }
    }

    /// GitLab API 版本標記；本片不含連線欄，僅保留版本字串。預設 "v4"。
    public var version: String

    /// 輪詢設定；預設週期 60 秒。
    public var poll: Poll

    /// 以顯式欄位建立；各欄帶預設值，等同 `.default`。
    public init(version: String = "v4", poll: Poll = .init()) {
        self.version = version
        self.poll = poll
    }

    /// 解碼缺欄時逐欄回落預設（`version` → "v4"、`poll` → 預設）。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? "v4"
        self.poll = try container.decodeIfPresent(Poll.self, forKey: .poll) ?? .init()
    }

    /// 無 CLI 引數覆寫時採用的預設組態。
    public static let `default`: Config = .init()
}
