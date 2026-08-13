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

/// 寫入端行為。
private final class DecisionLogFileTests {

    /// 各測試各自的空目錄，測試結束一併移除。
    private let directory: URL

    /// 全部紀錄共用的整秒時刻。
    private let at: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 建一個本次測試專用的空目錄。
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("decision-log-file-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 測試結束後把整個暫存目錄移除。
    deinit {
        // 清不掉也不該讓測試失敗——暫存目錄留著，下次由系統回收。
        try? FileManager.default.removeItem(at: directory)
    }

    /// 本測試檔的日誌檔位置。
    private var logURL: URL { directory.appendingPathComponent("decisions.ndjson", isDirectory: false) }

    /// 造一則決策紀錄；`reason` 當識別用。
    private func decision(reason: String) -> DecisionLogEntry {
        .decision(
            .init(
                decidedAt: at,
                eventKey: "v1|mr_outdated|group/project|merge_request|42",
                eventType: "mr_outdated",
                project: "group/project",
                disposition: .dispatched,
                reason: reason,
                inputs: ["labels": "ci"]
            )
        )
    }

    /// 直接讀回日誌檔的原始 bytes。
    private func rawBytes() throws -> Data { try .init(contentsOf: logURL) }

    /// 檔案不存在時，第一次 append 會把它建出來，內容就是那一行加一個換行。
    @Test
    func `creates the file on first append`() async throws {
        let file: DecisionLogFile = .init(url: logURL)
        let entry: DecisionLogEntry = decision(reason: "first")
        try await file.append(entry)
        let expected: Data = .init((try entry.jsonLine() + "\n").utf8)
        #expect(try rawBytes() == expected)
    }

    /// 新建的日誌檔只有擁有者可讀寫。
    @Test
    func `creates the file readable only by its owner`() async throws {
        let file: DecisionLogFile = .init(url: logURL)
        try await file.append(decision(reason: "first"))
        let attributes: [FileAttributeKey: Any] = try FileManager.default.attributesOfItem(atPath: logURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    }

    /// 多次 append 逐行累加、順序即寫入順序。
    @Test
    func `appends one line per record in write order`() async throws {
        let file: DecisionLogFile = .init(url: logURL)
        try await file.append(decision(reason: "first"))
        try await file.append(contentsOf: [decision(reason: "second"), decision(reason: "third")])
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: logURL)
        #expect(result.entries == [decision(reason: "first"), decision(reason: "second"), decision(reason: "third")])
        #expect(result.malformedLines.isEmpty)
        #expect(result.hasUnterminatedTail == false)
    }

    /// 寫空序列什麼都不做——連檔案都不建。「這輪沒有決策」不該在磁碟上留下痕跡。
    @Test
    func `writing no records leaves the file system untouched`() async throws {
        let file: DecisionLogFile = .init(url: logURL)
        try await file.append(contentsOf: [])
        #expect(FileManager.default.fileExists(atPath: logURL.path) == false)
    }

    /// 上一次寫到一半留下的殘句，不會和下一則紀錄黏成一行——殘句留在自己那一行、新紀錄完好。
    @Test
    func `terminates a torn tail before appending`() async throws {
        try Data(#"{"decision":{"schemaVer"#.utf8).write(to: logURL)
        let file: DecisionLogFile = .init(url: logURL)
        let entry: DecisionLogEntry = decision(reason: "after crash")
        try await file.append(entry)
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: logURL)
        #expect(result.entries == [entry])
        #expect(result.malformedLines.map(\.number) == [1])
        #expect(result.hasUnterminatedTail == false)
    }

    /// 檔案已以換行正常結尾時不補換行——不會插出一個空行。
    @Test
    func `does not insert a blank line when the file already ends cleanly`() async throws {
        let file: DecisionLogFile = .init(url: logURL)
        try await file.append(decision(reason: "first"))
        try await file.append(decision(reason: "second"))
        #expect(try rawBytes().split(separator: 0x0A, omittingEmptySubsequences: false).count == 3)
    }

    /// 另一個實例接手同一個檔時是接著寫、不是從頭來過——既有紀錄一則都不會少。
    @Test
    func `does not truncate a log another instance already wrote`() async throws {
        try await DecisionLogFile(url: logURL).append(decision(reason: "first"))
        try await DecisionLogFile(url: logURL).append(decision(reason: "second"))
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: logURL)
        #expect(result.entries == [decision(reason: "first"), decision(reason: "second")])
    }

    /// 併發 append 不互相覆蓋：每一則都在、都完好。
    @Test
    func `serialises concurrent appends`() async throws {
        let file: DecisionLogFile = .init(url: logURL)
        let entries: [DecisionLogEntry] = (0..<32).map { decision(reason: "concurrent-\($0)") }
        await withTaskGroup(of: Void.self) { group in
            for entry: DecisionLogEntry in entries {
                // 這裡吞掉失敗無妨：下面對筆數與內容的斷言會把任何一則沒寫成的情況抓出來。
                group.addTask { try? await file.append(entry) }
            }
        }
        let result: DecisionLogFileReader.ReadResult = try DecisionLogFileReader.read(contentsOf: logURL)
        #expect(result.malformedLines.isEmpty)
        #expect(result.hasUnterminatedTail == false)
        #expect(result.entries.count == entries.count)
        #expect(entries.allSatisfy(result.entries.contains))
    }
}
