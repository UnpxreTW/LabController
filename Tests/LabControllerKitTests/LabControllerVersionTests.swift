//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

@testable import LabControllerKit
import Testing

/// 建置時產生的版本常數，以及它與 runner 自述之間的接線。
///
/// 版本字串由建置當下的 git 狀態推導，值會隨標籤與 checkout 形狀而變，
/// 因此這裡只斷言形狀與接線、不比對特定字面值。
private final class LabControllerVersionTests {

    /// 版本字串永遠有值：取不到 git 資訊時也會回落成 `unknown`，不會是空字串。
    @Test
    func `the generated version is never empty`() {
        #expect(LabControllerVersion.current.isEmpty == false)
    }

    /// 形狀限定在三種：語意化版號（含 `describe` 的後綴形）、純 commit sha、`unknown`。
    @Test
    func `the generated version has one of the expected shapes`() {
        let value: String = LabControllerVersion.current
        let isSemantic: Bool = value.wholeMatch(of: /\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?/) != nil
        let isCommitHash: Bool = value.wholeMatch(of: /[0-9a-f]{7,40}/) != nil
        #expect(isSemantic || isCommitHash || value == "unknown")
    }

    /// runner 自述的版本欄預設取建置時版本，而不是寫死的字面值。
    @Test
    func `runner info reports the build version by default`() {
        #expect(RunnerInfo().version == LabControllerVersion.current)
    }

    /// 呼叫端仍可顯式覆寫版本欄。
    @Test
    func `runner info still accepts an explicit version`() {
        #expect(RunnerInfo(version: "9.9.9").version == "9.9.9")
    }
}
