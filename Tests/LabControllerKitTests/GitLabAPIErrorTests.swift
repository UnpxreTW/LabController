//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
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

    /// 傳輸層拋的 `URLError` 帶著送出去的整條網址，描述只留錯誤碼與收斂後的位置。
    @Test
    func `transport errors are described without the credentials they carry`() {
        let leaky: String = "https://oauth2:glpat-synthetic@gitlab.example.com/api/v4/jobs/request"
        guard let url: URL = .init(string: leaky) else {
            Issue.record("合成網址字面值應解得開")
            return
        }
        let error: URLError = .init(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        #expect(String(describing: error).contains("glpat-synthetic"))
        let description: String = GitLabAPIError.safeDescription(of: error)
        #expect(!description.contains("glpat-synthetic"))
        #expect(description.contains("https://gitlab.example.com"))
        #expect(description.contains("\(URLError.Code.cannotConnectToHost.rawValue)"))
    }

    /// 拿不到失敗網址時不編一個出來，回固定替代字串。
    @Test
    func `transport errors without a failing url yield the fixed placeholder`() {
        let description: String = GitLabAPIError.safeDescription(of: URLError(.timedOut))
        #expect(description.contains(GitLabAPIError.unparsableLocation))
    }

    /// 非傳輸層的錯誤照原樣描述：本模組自己的錯誤在建立處就已收斂。
    @Test
    func `other errors keep their own description`() {
        #expect(
            GitLabAPIError.safeDescription(of: GitLabAPIError.unexpectedStatus(403))
                == String(describing: GitLabAPIError.unexpectedStatus(403))
        )
    }
}
