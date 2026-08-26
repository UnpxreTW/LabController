//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一道被要求必須成功的命令沒有以零結束。
///
/// 帶著整份結果而不是只帶結束碼：查一個失敗的命令，第一件要看的是它印了什麼，而那份輸出在
/// 拋出的當下不抄走就沒有第二次機會。
public struct CommandFailure: Error, Equatable, Sendable {

    /// 完整結果。
    public let result: CommandResult

    /// 以結果建立。
    public init(result: CommandResult) {
        self.result = result
    }
}
