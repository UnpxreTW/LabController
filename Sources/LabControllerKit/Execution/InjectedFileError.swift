//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 注入檔說不通的地方。
public enum InjectedFileError: Error, Equatable, Sendable {

    /// 路徑不是絕對路徑；相對路徑要對誰而言本側答不出來。
    case pathNotAbsolute(String)

    /// 路徑含 `..` 段；實際落點與字面不同。
    case pathHasRelativeComponent(String)

    /// 權限位元超出八進位三碼能表示的範圍。
    case permissionsOutOfRange(UInt16)
}
