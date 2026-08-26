//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 開機時放進執行環境的一份檔案。
public struct InjectedFile: Sendable, Equatable {

    /// 環境內的絕對路徑。
    public let path: String

    /// 檔案內容。
    public let contents: Data

    /// 權限位元，八進位；預設 `0o600`。
    ///
    /// **預設關到最緊**：這條路徑存在的理由就是送憑證進去，而預設值寬掉的那一次不會有任何
    /// 徵兆——檔案讀得到、job 照樣綠，只是環境裡的每一個行程都讀得到它。要放寬的呼叫端自己
    /// 寫出來，讓那個決定留在程式碼裡看得見。
    public let permissions: UInt16

    /// 建立；路徑與權限在此驗，不合的當場拋。
    ///
    /// 驗在建立這一刻而不是寫入那一刻：一份不合的注入檔通常來自組態或呼叫端的算路徑邏輯，
    /// 而那時候環境還沒開——晚到寫入才擋，代價是已經開好的環境要收拾，而收拾的路徑正是
    /// 最少被走到、也最容易漏的那一條。
    ///
    /// - Throws: ``InjectedFileError``。
    public init(path: String, contents: Data, permissions: UInt16 = 0o600) throws {
        guard path.hasPrefix("/") else { throw InjectedFileError.pathNotAbsolute(path) }
        // 相對段是在**環境內**解析的，本側看不到解析結果——擋掉的理由不是「一定有惡意」，
        // 是「寫的人以為自己指到哪裡」與實際落點可能不同，而落差的內容是憑證。
        guard !path.split(separator: "/").contains("..") else {
            throw InjectedFileError.pathHasRelativeComponent(path)
        }
        guard permissions <= 0o777 else { throw InjectedFileError.permissionsOutOfRange(permissions) }
        self.path = path
        self.contents = contents
        self.permissions = permissions
    }
}
