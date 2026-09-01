//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Testing

/// 把內容寫成一個暫存檔，回傳路徑；測試結束後由暫存目錄自行清理。
private func temporaryFile(containing contents: String) throws -> String {
    let path: String = FileManager.default.temporaryDirectory
        .appending(component: "runner-token-\(UUID().uuidString)")
        .path
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private final class RunnerTokenFileTests {

    /// 尾端換行去掉——這種檔多半是別的機器寫好搬過來的，帶著換行送出去只會換來一句認證失敗。
    @Test
    func `strips surrounding whitespace and newlines`() throws {
        let path: String = try temporaryFile(containing: "  synthetic-runner-token\n\n")
        #expect(try RunnerTokenFile.read(atPath: path) == "synthetic-runner-token")
    }

    /// 檔案本來就乾淨時原樣讀出。
    @Test
    func `reads a clean file as is`() throws {
        let path: String = try temporaryFile(containing: "synthetic-runner-token")
        #expect(try RunnerTokenFile.read(atPath: path) == "synthetic-runner-token")
    }

    /// 只有空白的檔案當成空的：帶一個空字串去領件，站台回的錯與 token 打錯時一模一樣。
    @Test
    func `treats a blank file as empty`() throws {
        let path: String = try temporaryFile(containing: "\n   \n")
        #expect(throws: RunnerTokenFile.ReadError.empty(path: path)) {
            try RunnerTokenFile.read(atPath: path)
        }
    }

    /// 檔案不在就說檔案不在，與「檔案在但沒東西」分成兩種錯。
    @Test
    func `reports an unreadable file separately`() {
        let path: String = "/nonexistent/runner-token"
        #expect(throws: RunnerTokenFile.ReadError.unreadable(path: path)) {
            try RunnerTokenFile.read(atPath: path)
        }
    }
}
