//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把 ``DecisionLogFile`` 寫出的 NDJSON 檔讀回成紀錄。
///
/// ## 為什麼壞行不讓整份讀取失敗
///
/// 這份日誌的用途是事故取證，而會需要取證的場合，日誌本身多半也不完美——當機留下的半行、
/// 舊版 binary 寫的行、被別的工具動過的行。一則壞行就讓整份讀不出來，等於「日誌在最需要它的
/// 時候失效」。因此讀取端把壞行**當成結果的一部分照實回報**（行號＋原文），不丟棄也不假裝沒有：
/// 呼叫端拿得到讀得出來的每一則，也看得見哪幾行讀不出來、原文長什麼樣。
///
/// 不附解碼錯誤本身，是因為原文就是證據——真要知道為什麼壞，拿那一行原文丟回
/// ``DecisionLogEntry/init(jsonLine:)`` 就會得到當下那個錯誤，不必在這裡把它塞成字串保存。
///
/// ⚠ 讀取會把整份日誌載進記憶體，設計給取證與測試用；日誌長到不適合整份載入時，該換成串流讀取。
public enum DecisionLogFileReader {

    /// 讀取失敗的具名原因。
    public enum Failure: Error, Equatable {

        /// 檔案內容不是合法 UTF-8。整份日誌的編碼壞掉不是逐行能處理的問題——切行本身就已經不可信。
        case notUTF8(path: String)
    }

    /// 換行位元組；NDJSON 的行終止符。
    private static let newline: UInt8 = 0x0A

    /// 讀不出來的一行。
    public struct MalformedLine: Sendable, Equatable {

        /// 行號，自 1 起算；與用編輯器打開時看到的行號一致。
        public let number: Int

        /// 該行原文，不含換行。
        public let text: String

        /// 建立一筆壞行紀錄。
        public init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
    }

    /// 一次讀取的結果。
    public struct ReadResult: Sendable, Equatable {

        /// 讀得出來的紀錄，依檔案中的行序。
        public let entries: [DecisionLogEntry]

        /// 讀不出來的行。
        public let malformedLines: [MalformedLine]

        /// 檔案結尾是否留著一段沒有換行結尾的殘句。
        ///
        /// 有殘句代表最後一次寫入被打斷（行程當機、磁碟寫滿）。那段殘句**不會**被當成紀錄去解——
        /// 它是不完整的內容，不論解得出來與否都不該被當成一則發生過的事實。
        public let hasUnterminatedTail: Bool

        /// 建立一份讀取結果。
        public init(entries: [DecisionLogEntry], malformedLines: [MalformedLine], hasUnterminatedTail: Bool) {
            self.entries = entries
            self.malformedLines = malformedLines
            self.hasUnterminatedTail = hasUnterminatedTail
        }
    }

    /// 讀回一份日誌。
    ///
    /// 檔案不存在時照實丟出檔案系統的錯誤，**不當成空日誌**——「還沒有任何紀錄」與「路徑打錯」
    /// 是兩件事，把後者悄悄變成前者會讓查不到東西的原因永遠查不出來。
    ///
    /// **切行在 byte 層做、不在 `String` 層**：`String` 以字素叢集比對，`\r\n` 是**一個**字素，
    /// 拿 `"\n"` 去切會切不開它——一份被別的工具寫成 CRLF 的日誌會整段黏成一行、每一行都變壞行。
    /// NDJSON 的行分隔本來就定義在 byte 上（`0x0A`），照 byte 切才是對的層級。合法 UTF-8 裡
    /// `0x0A` 只可能是換行本身（後續 byte 一律 ≥ `0x80`），所以切完每段仍是合法 UTF-8。
    ///
    /// - Parameter url: 日誌檔位置。
    /// - Returns: 讀得出來的紀錄、讀不出來的行、以及結尾有無殘句。
    /// - Throws: ``Failure/notUTF8(path:)`` 或檔案系統本身的錯誤。
    public static func read(contentsOf url: URL) throws -> ReadResult {
        let data: Data = try .init(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil else { throw Failure.notUTF8(path: url.path) }
        // 以換行切開後，最後一段是最後一個換行**之後**的內容：檔案正常結尾時它是空的，非空即代表有殘句。
        var segments: [Data.SubSequence] = data.split(separator: newline, omittingEmptySubsequences: false)
        let tail: Data.SubSequence = segments.popLast() ?? .init()
        var entries: [DecisionLogEntry] = []
        var malformedLines: [MalformedLine] = []
        for (offset, segment): (Int, Data.SubSequence) in segments.enumerated() {
            // 空行不是紀錄也不是錯誤：本型別寫不出空行，但日誌是純文字檔、別的工具動過它是可能的，
            // 為此報一則錯只會製造雜訊。
            guard !segment.isEmpty else { continue }
            // 整份已驗過是合法 UTF-8、且切點只落在換行上，所以這裡的轉換不會替換掉任何 byte。
            let line: String = .init(decoding: segment, as: UTF8.self)
            // 這裡不留解碼錯誤是刻意的（理由見型別說明）：讀不出來就是讀不出來，原文才是證據。
            if let entry: DecisionLogEntry = try? .init(jsonLine: line) {
                entries.append(entry)
            } else {
                malformedLines.append(.init(number: offset + 1, text: line))
            }
        }
        return .init(entries: entries, malformedLines: malformedLines, hasUnterminatedTail: !tail.isEmpty)
    }
}
