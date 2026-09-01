//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 從檔案讀出 runner 認證 token。
///
/// 存在的理由是那個尾端換行：這種檔多半是別的機器寫好再搬過來的，編輯器與 `scp` 都會留一個
/// `\n`。原樣送出去時站台只回一句認證失敗，看起來與「token 過期」「打錯字」完全一樣，而檔案
/// 用眼睛看又是對的——這一關把它去掉，並且把「檔案是空的」與「讀不到檔案」分成兩種錯誤。
public enum RunnerTokenFile {

    /// 讀檔失敗的原因。
    public enum ReadError: Error, Equatable {

        /// 檔案讀不出來（不存在、沒有權限、不是有效的 UTF-8）。
        ///
        /// 只帶路徑、不帶底層錯誤的內容：那份訊息在某些情況下會把檔案內容的片段帶出來，
        /// 而這個檔案裡放的是一把 token。
        case unreadable(path: String)

        /// 檔案讀得到，但去掉前後空白之後什麼都不剩。
        case empty(path: String)
    }

    /// 讀出 token；前後的空白與換行一律去掉。
    ///
    /// - Parameter path: token 檔的路徑。
    /// - Returns: 去過空白的 token 字串。
    /// - Throws: ``ReadError``。
    public static func read(atPath path: String) throws -> String {
        guard let contents: String = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ReadError.unreadable(path: path)
        }
        let token: String = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ReadError.empty(path: path) }
        return token
    }
}
