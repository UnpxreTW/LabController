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

private final class DecisionLogEntryTests {

    /// 除了測時刻精度那條以外，都用同一個整秒時刻。
    private let at: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 一則決策紀錄編成一行再讀回，值不變。
    @Test
    func `round-trips a decision record`() throws {
        let record: DecisionRecord = .init(
            decidedAt: at,
            eventKey: "v1|mr_outdated|group/project|merge_request|42",
            eventType: "mr_outdated",
            project: "group/project",
            disposition: .dispatched,
            reason: "source branch behind target",
            inputs: ["labels": "ci"]
        )
        let entry: DecisionLogEntry = .decision(record)
        let line: String = try entry.jsonLine()
        let restored: DecisionLogEntry = try .init(jsonLine: line)
        #expect(restored == entry)
    }

    /// 一則 job 紀錄（含 LLM 帳目）編成一行再讀回，值不變。
    @Test
    func `round-trips a job record with llm calls`() throws {
        let record: JobRecord = .init(
            recordedAt: at,
            eventKey: "v1|mr_outdated|group/project|merge_request|42",
            jobSpecSHA: "a1b2c3",
            guestResult: .completed,
            hostVerification: .confirmed,
            llmCalls: [
                .init(model: "gpt-120b", purpose: "conflict_resolution", tokens: 1200, latencySeconds: 4.2),
                .init(
                    model: "qwen3.5-122b",
                    purpose: "review",
                    tokens: 3400,
                    latencySeconds: 17.5,
                    promptEvalCount: 3000,
                    evalCount: 400
                ),
            ],
            needsHuman: false
        )
        let entry: DecisionLogEntry = .job(record)
        let restored: DecisionLogEntry = try .init(jsonLine: entry.jsonLine())
        #expect(restored == entry)
    }

    /// 欄位值再敵意（換行、組合字元、分隔字元）也編不出真正的換行——NDJSON 逐行可切的前提。
    @Test
    func `produces a single line even with hostile field values`() throws {
        let record: DecisionRecord = .init(
            decidedAt: at,
            eventKey: "v1|weird\\|proj|merge_request|1",
            eventType: "mr_outdated",
            project: "group/pro\nject",
            disposition: .skipped,
            reason: "line one\nline two\r\ttabbed",
            inputs: ["note": "combining \u{0301} mark", "pipe": "a|b"]
        )
        let line: String = try DecisionLogEntry.decision(record).jsonLine()
        // 逐 byte 判斷、不用 `String.contains`：後者走 grapheme cluster 比對，`\r\n` 是單一
        // Character，`"a\r\nb".contains("\n")` 會回 false——那樣的斷言釘不住單行保證。
        #expect(!line.utf8.contains(0x0A))
        #expect(!line.utf8.contains(0x0D))
        let restored: DecisionLogEntry = try .init(jsonLine: line)
        #expect(restored == .decision(record))
    }

    /// 同一則紀錄每次都編出逐 byte 相同的字串（sortedKeys 擔保、diff 乾淨）。
    @Test
    func `encodes keys in a stable order`() throws {
        let entry: DecisionLogEntry = .decision(
            .init(
                decidedAt: at,
                eventKey: "k",
                eventType: "mr_outdated",
                project: "p",
                disposition: .detected,
                reason: "r"
            )
        )
        #expect(try entry.jsonLine() == entry.jsonLine())
    }

    /// 每一行都自帶格式版本。
    @Test
    func `carries the schema version on every line`() throws {
        let entry: DecisionLogEntry = .decision(
            .init(
                decidedAt: at,
                eventKey: "k",
                eventType: "mr_outdated",
                project: "p",
                disposition: .detected,
                reason: "r"
            )
        )
        #expect(try entry.jsonLine().contains("\"schemaVersion\":\"v1\""))
        #expect(DecisionLogEntry.schemaVersion == "v1")
    }

    /// 既不是決策也不是 job 的一行，明確丟 `unknownLineShape`、不靜靜落成空紀錄。
    @Test
    func `rejects a line that is neither decision nor job`() {
        #expect(throws: DecisionLogEntry.CodingFailure.unknownLineShape) {
            try DecisionLogEntry(jsonLine: "{\"other\":{}}")
        }
    }

    /// 頂層同時帶 decision 與 job 兩個鍵——不靜靜取其一，明確丟 `unknownLineShape`。
    @Test
    func `rejects a line that carries both record kinds`() {
        #expect(throws: DecisionLogEntry.CodingFailure.unknownLineShape) {
            try DecisionLogEntry(jsonLine: "{\"decision\":{},\"job\":{}}")
        }
    }

    /// 鍵在、但紀錄本體缺必填欄——照實丟解碼錯，不被壓成「鍵缺席」而吞掉。
    @Test
    func `does not swallow a malformed record`() {
        #expect(throws: (any Error).self) {
            try DecisionLogEntry(jsonLine: "{\"decision\":{\"eventKey\":\"k\"}}")
        }
    }

    /// 時刻精度：`iso8601` 不含小數秒，次秒部分在編碼時被截掉——明文釘住這個行為。
    @Test
    func `truncates sub-second precision on the timestamp`() throws {
        let subSecond: Date = .init(timeIntervalSince1970: 1_800_000_000.75)
        let wholeSecond: Date = .init(timeIntervalSince1970: 1_800_000_000)
        let entry: DecisionLogEntry = .decision(
            .init(
                decidedAt: subSecond,
                eventKey: "k",
                eventType: "mr_outdated",
                project: "p",
                disposition: .detected,
                reason: "r"
            )
        )
        let restored: DecisionLogEntry = try .init(jsonLine: entry.jsonLine())
        guard case let .decision(record) = restored else {
            Issue.record("expected a decision record")
            return
        }
        #expect(record.decidedAt == wholeSecond)
    }
}
