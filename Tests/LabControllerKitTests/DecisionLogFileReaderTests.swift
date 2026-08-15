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

/// 讀取端行為。
private final class DecisionLogFileReaderTests {

    /// 各測試各自的空目錄，測試結束一併移除。
    private let directory: URL

    /// 建一個本次測試專用的空目錄。
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decision-log-reader-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 測試結束後把整個暫存目錄移除。
    deinit {
        // 清不掉也不該讓測試失敗——暫存目錄留著，下次由系統回收。
        try? FileManager.default.removeItem(at: directory)
    }

    /// 把給定 bytes 寫成日誌檔並回傳位置。
    private func makeLog(_ bytes: Data) throws -> URL {
        let url: URL = directory.appendingPathComponent("\(UUID().uuidString).ndjson", isDirectory: false)
        try bytes.write(to: url)
        return url
    }

    /// 一則可解的決策紀錄行。
    private func validLine() throws -> String {
        try DecisionLogEntry.decision(
            .init(
                decidedAt: .init(timeIntervalSince1970: 1_800_000_000),
                eventKey: "v1|mr_outdated|group/project|merge_request|42",
                eventType: "mr_outdated",
                project: "group/project",
                disposition: .skipped,
                reason: "deduplicated",
                inputs: [:]
            )
        )
        .jsonLine()
    }

    /// 壞行不讓整份讀取失敗：好行照樣讀得出來，壞行以行號與原文回報。
    @Test
    func `reports malformed lines without dropping the readable ones`() throws {
        let line: String = try validLine()
        let url: URL = try makeLog(Data("\(line)\n{\"other\":1}\n\(line)\n".utf8))
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: url)
        #expect(result.entries.count == 2)
        #expect(result.malformedLines == [.init(number: 2, text: "{\"other\":1}")])
    }

    /// 沒有換行結尾的殘句不會被當成紀錄去解，且會被回報出來。
    @Test
    func `never parses an unterminated tail as a record`() throws {
        let line: String = try validLine()
        let url: URL = try makeLog(Data("\(line)\n\(line)".utf8))
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: url)
        #expect(result.entries.count == 1)
        #expect(result.malformedLines.isEmpty)
        #expect(result.hasUnterminatedTail)
    }

    /// 空行跳過，不算紀錄也不算壞行。
    @Test
    func `skips blank lines`() throws {
        let line: String = try validLine()
        let url: URL = try makeLog(Data("\(line)\n\n\(line)\n".utf8))
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: url)
        #expect(result.entries.count == 2)
        #expect(result.malformedLines.isEmpty)
    }

    /// 空檔讀成零紀錄、無殘句。
    @Test
    func `reads an empty file as no records`() throws {
        let url: URL = try makeLog(.init())
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: url)
        #expect(result.entries.isEmpty)
        #expect(result.malformedLines.isEmpty)
        #expect(result.hasUnterminatedTail == false)
    }

    /// CRLF 結尾的檔照樣逐行切得開。
    ///
    /// `String` 把 `\r\n` 當**一個**字素，以字素層切行會切不開它——整份日誌會塌成一行、一則都讀不出來。
    /// 切點落在 byte 層才有這裡的兩則。（尾隨的 `\r` 對 JSON 而言是空白，不影響該行解得出來。）
    @Test
    func `splits lines on the newline byte even with carriage returns`() throws {
        let line: String = try validLine()
        let url: URL = try makeLog(Data("\(line)\r\n\(line)\n".utf8))
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: url)
        #expect(result.entries.count == 2)
        #expect(result.malformedLines.isEmpty)
        #expect(result.hasUnterminatedTail == false)
    }

    /// 整份不是合法 UTF-8 時照實丟錯——切行本身就已經不可信，不逐行含混帶過。
    @Test
    func `rejects a file that is not valid UTF-8`() throws {
        let url: URL = try makeLog(Data([0xFF, 0xFE, 0x0A]))
        #expect(throws: DecisionLogFileReader.Failure.notUTF8(path: url.path)) {
            try DecisionLogFileReader.read(contentsOf: url)
        }
    }

    /// 檔案不存在照實丟錯，不當成空日誌——路徑打錯與尚無紀錄是兩件事。
    @Test
    func `throws when the file does not exist`() throws {
        let url: URL = directory.appendingPathComponent("missing.ndjson", isDirectory: false)
        #expect(throws: (any Error).self) {
            try DecisionLogFileReader.read(contentsOf: url)
        }
    }
}
