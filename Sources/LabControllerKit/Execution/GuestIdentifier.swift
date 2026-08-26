//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一個執行環境的識別碼；由後端發放，對本側而言是不透明字串。
///
/// **刻意不解析、也不對格式做任何承諾**：一個後端可能發 UUID、另一個可能發容器 id 或 VM 名。
/// 本側只要能把它原樣交回去（`exec`／`status`／`destroy`）就夠了。從裡面讀出「這是哪一種
/// guest」的那一刻，換一個後端就會讀出垃圾，而讀出垃圾的路徑不會報錯、只會做錯事。
///
/// 同理，它出現在對外面（MCP 面板等）時仍是不透明的——外面看到的是同一個字串，
/// 而不是主機路徑或容器名。
public struct GuestIdentifier: Hashable, Sendable, CustomStringConvertible {

    /// 後端發放的原字串。
    public let rawValue: String

    /// 以後端回傳的字串建立。
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// 日誌與錯誤訊息中的呈現形式，即識別碼本身。
    public var description: String {
        rawValue
    }
}
