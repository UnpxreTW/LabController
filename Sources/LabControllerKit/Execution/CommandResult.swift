//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 在執行環境裡跑完一道命令的結果。
///
/// **離開零的那個結束碼是資料、不是錯誤**：`swiftlint` 找到問題、`git push` 被拒、測試紅——
/// 這些都是命令好好跑完之後給出的答案，呼叫端多半要看內容再決定怎麼辦。把非零一律轉成拋出，
/// 等於逼每一個呼叫端先接住例外再從裡面把答案挖回來，而挖漏的那一次會表現成「一個失敗的命令
/// 被當成沒發生」。真正的錯誤是**沒跑成**（環境不在、送不進去），那類走
/// ``ExecutionBackendError``。
public struct CommandResult: Sendable, Equatable {

    /// 跑的是哪道命令，逐個參數。
    ///
    /// 帶在結果裡，錯誤訊息才不必由呼叫端自己再拼一次——拼的那份常常與真正送出去的不一致。
    public let command: [String]

    /// 結束碼。
    public let exitCode: Int32

    /// 標準輸出的原始位元組。
    public let standardOutput: Data

    /// 標準錯誤的原始位元組。
    public let standardError: Data

    /// 逐欄建立。
    public init(command: [String], exitCode: Int32, standardOutput: Data = .init(), standardError: Data = .init()) {
        self.command = command
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// 命令是否以零結束。
    public var isSuccess: Bool {
        exitCode == 0
    }

    /// 標準輸出解成文字；不是 UTF-8 的位元組以替換字元呈現。
    ///
    /// **原始位元組才是正本**（``standardOutput``）：輸出可能是二進位，也可能是要拿去逐 byte
    /// 比對的東西，而解碼會把不合法的序列換成替換字元——比對因此永遠會過。要給人看的走這裡，
    /// 要拿去比的走原始位元組。
    public var standardOutputText: String {
        .init(decoding: standardOutput, as: UTF8.self)
    }

    /// 標準錯誤解成文字；規則同 ``standardOutputText``。
    public var standardErrorText: String {
        .init(decoding: standardError, as: UTF8.self)
    }

    /// 要求這道命令必須成功；非零即拋。
    ///
    /// 給「非零就是壞了、沒有第二種讀法」的呼叫端用（例如環境裡的前置佈置步驟）。判斷仍留在
    /// 呼叫端——這個型別本身不預設任何一種讀法。
    ///
    /// - Returns: 結束碼為零時回自己，方便串下去。
    /// - Throws: ``CommandFailure``，內含完整結果。
    @discardableResult
    public func requireSuccess() throws -> Self {
        guard isSuccess else { throw CommandFailure(result: self) }
        return self
    }
}
