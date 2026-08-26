//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一份 ``JobPlan`` 鋪不成執行環境裡的檔案樹。
///
/// 每一則都是「鋪出去會出事」而不是「鋪起來不好看」：變數名寫進 shell 檔就會被求值，
/// 一個帶著空白或分號的名字等於一段被執行的內容。這些一律在鋪之前擋下——環境都還沒開，
/// 收拾成本最低。
public enum JobWorkspaceError: Error, Equatable, Sendable {

    /// 工作根不是絕對路徑；相對於誰，本側答不出來。
    case rootNotAbsolute(String)

    /// 變數名不是合法的 shell 識別字（只收 ASCII 字母、數字與底線，且不以數字開頭）。
    case invalidVariableName(String)

    /// 變數名佔用了本側自用的前綴（見 ``JobWorkspace/reservedPrefix``）。
    ///
    /// 擋下而不是默默覆蓋：本側靠那幾個名字把取碼座標交給腳本，被 payload 端同名變數蓋掉時
    /// 症狀是「clone 到別的地方去」，而那個 job 仍會照常跑完。
    case reservedVariableName(String)

    /// 同一個名字出現兩次；後寫的 `export` 會靜默蓋掉前一個。
    case duplicateVariableName(String)

    /// 站台送了 `git_info`、但少了取碼所需的座標（見 ``GitInfo/hasIncompleteCoordinates``）。
    case incompleteGitCoordinates
}
