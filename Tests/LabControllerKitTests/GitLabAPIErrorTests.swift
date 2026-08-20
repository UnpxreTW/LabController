//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import LabControllerKit
import Testing

/// 網址位置描述的收斂規則：錯誤帶得出「打在哪」，帶不出憑證。
///
/// 全部為合成資料（假 token、假站台名），不含任何真實站台內容。
private final class GitLabAPIErrorTests {

    /// 使用者名稱與密碼一律不留。
    @Test
    func `credentials in userinfo are dropped`() {
        let location: String = GitLabAPIError.safeLocation(of: "https://oauth2:glpat-synthetic@gitlab.example.com")
        #expect(location == "https://gitlab.example.com")
    }

    /// port 是分辨站台的一部分，保留。
    @Test
    func `scheme host and port are kept`() {
        #expect(GitLabAPIError.safeLocation(of: "https://gitlab.example.com:8443") == "https://gitlab.example.com:8443")
    }

    /// 路徑、查詢字串與片段一律不留：憑證也常被放進查詢字串。
    @Test
    func `path query and fragment are dropped`() {
        let location: String = GitLabAPIError.safeLocation(
            of: "https://gitlab.example.com/api/v4/jobs?private_token=glpat-synthetic#frag"
        )
        #expect(location == "https://gitlab.example.com")
    }

    /// 解不出 host 時回固定字串，不回退到原值。
    @Test
    func `unparsable input yields the fixed placeholder`() {
        #expect(GitLabAPIError.safeLocation(of: "") == GitLabAPIError.unparsableLocation)
        #expect(GitLabAPIError.safeLocation(of: "h.invalid") == GitLabAPIError.unparsableLocation)
        let location: String = GitLabAPIError.safeLocation(of: "https://oauth2:glpat-synthetic@gitlab example.com")
        #expect(!location.contains("glpat-synthetic"))
    }
}
