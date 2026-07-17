//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import LabControllerKit
import Testing

private final class LabControllerKitTests {

    /// LabControllerKit 目前僅有命名空間佔位 enum；本測試驗證模組可匯入、符號可解析。
    @Test
    func `module imports and namespace type resolves`() {
        #expect(String(describing: LabControllerKit.self) == "LabControllerKit")
    }
}
