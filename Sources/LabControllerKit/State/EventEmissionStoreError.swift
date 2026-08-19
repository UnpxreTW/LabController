//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 去重狀態庫的錯誤模型；涵蓋開檔、語句執行與結構版本三類失敗。
///
/// 每個 case 都帶得出「哪一步、資料庫怎麼說」——去重狀態壞掉的表現形式是**事件整批重發**或
/// **整批靜靜消失**，兩者都不會有其他徵兆，錯誤訊息若只寫「資料庫錯誤」就查不動。
public enum EventEmissionStoreError: Error, Equatable, Sendable {

    /// 資料庫檔開不起來；帶路徑與 SQLite 的原始碼與訊息。
    case openFailed(path: String, code: Int32, message: String)

    /// 某一步語句執行失敗；`operation` 是我方給該步驟的名字，不是 SQL 原文。
    ///
    /// **刻意不帶 SQL 原文與參數值**：這條錯誤會被寫進 log，而參數是事件鑰匙——鑰匙本身不是秘密，
    /// 但把整句 SQL 塞進 log 只會讓真正要看的那一句沉在雜訊裡。要對應到哪一句，看 `operation`。
    case statementFailed(operation: String, code: Int32, message: String)

    /// 資料庫檔的結構版本不是本型別認得的那一版。
    ///
    /// 這是**故意當場失敗**而不是照舊讀寫：欄位意義換代後仍照舊讀，最好的情況是解出錯的時刻、
    /// 最壞的情況是把新版寫壞。升級路徑（若日後有）由明確的遷移程序負責，不由讀取端猜。
    case unsupportedSchemaVersion(found: Int32, expected: Int32)
}
