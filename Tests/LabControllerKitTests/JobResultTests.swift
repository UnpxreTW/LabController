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

private final class JobResultTests {

    /// 把結果編出來再讀回去。
    private func roundTrip(_ result: JobResult) throws -> JobResult {
        try .init(jsonData: result.jsonData())
    }

    /// 讀一份手寫的結果檔。
    private func decode(_ json: String) throws -> JobResult {
        try .init(jsonData: Data(json.utf8))
    }

    /// 一份寫滿的結果來回一趟，每一欄都對得起來。
    @Test
    func `keeps every field of a result across a round trip`() throws {
        let result: JobResult = .init(
            status: .completed,
            actions: ["rebase", "push"],
            evidence: .init(
                pushedSHA: "abc123",
                filesChanged: ["Sources/A.swift"],
                llmCalls: [
                    .init(
                        model: "primary",
                        purpose: "conflict_resolution",
                        tokens: 128,
                        latencySeconds: 1.5,
                        promptEvalCount: 100,
                        evalCount: 28
                    ),
                ]
            ),
            stoppedAt: nil,
            needsHuman: false,
            reason: nil
        )
        let readBack: JobResult = try roundTrip(result)
        #expect(readBack == result)
        #expect(readBack.evidence.pushedSHA == "abc123")
        #expect(readBack.evidence.llmCalls.first?.promptEvalCount == 100)
        #expect(readBack.evidence.llmCalls.first?.evalCount == 28)
    }

    /// 沒帶規格版本時取當前版本——結果要能歸因到哪一版規格。
    @Test
    func `defaults the spec version to the current one`() throws {
        let result: JobResult = .init(status: .completed)
        #expect(result.specVersion == JobSpec.currentVersion)
        #expect(try roundTrip(result).specVersion == JobSpec.currentVersion)
    }

    /// 沒推東西不是失敗：乾淨且已經最新的分支本來就不該推。
    @Test
    func `reads a completed result that pushed nothing`() throws {
        let json: String = """
        {"specVersion":"v1","status":"completed","actions":["nothing to do"],\
        "evidence":{"filesChanged":[],"llmCalls":[]},"needsHuman":false}
        """
        let result: JobResult = try decode(json)
        #expect(result.status == .completed)
        #expect(result.evidence.pushedSHA == nil)
        #expect(result.stoppedAt == nil)
    }

    /// 收手時記下停在哪一條——沒有這一筆，事後就分不出哪條規則在攔東西、哪條從沒響過。
    @Test
    func `keeps the abort condition that stopped the run`() throws {
        let result: JobResult = .init(
            status: .jobFailed,
            stoppedAt: .noProgress,
            needsHuman: true,
            reason: "連續三回合沒有已驗證的進展"
        )
        let readBack: JobResult = try roundTrip(result)
        #expect(readBack.stoppedAt == .noProgress)
        #expect(readBack.needsHuman)
        #expect(readBack.reason == "連續三回合沒有已驗證的進展")
    }

    /// 七條收手條件各自來回一趟都保值。
    @Test
    func `keeps every abort condition across a round trip`() throws {
        for condition in JobAbortCondition.allCases {
            let result: JobResult = .init(status: .timeout, stoppedAt: condition)
            #expect(try roundTrip(result).stoppedAt == condition)
        }
    }

    /// 認不得的結果類別丟錯，不落成任何一種既有的類別。
    @Test
    func `rejects a status it does not know`() throws {
        let json: String = """
        {"specVersion":"v1","status":"mostly_fine","actions":[],\
        "evidence":{"filesChanged":[],"llmCalls":[]},"needsHuman":false}
        """
        #expect(throws: (any Error).self) { try self.decode(json) }
    }

    /// 缺了結果類別就丟錯——沒有這一欄的結果檔不是一次正常收尾。
    @Test
    func `rejects a result missing its status`() throws {
        let json: String = """
        {"specVersion":"v1","actions":[],"evidence":{"filesChanged":[],"llmCalls":[]},"needsHuman":false}
        """
        #expect(throws: (any Error).self) { try self.decode(json) }
    }

    /// 佐證欄壞掉一樣丟錯，不把整包佐證吞成空的。
    @Test
    func `rejects a result whose evidence is malformed`() throws {
        let json: String = """
        {"specVersion":"v1","status":"completed","actions":[],\
        "evidence":{"filesChanged":"Sources/A.swift","llmCalls":[]},"needsHuman":false}
        """
        #expect(throws: (any Error).self) { try self.decode(json) }
    }

    /// 同一份結果每次編出逐 byte 相同的內容。
    @Test
    func `encodes the same result to identical bytes every time`() throws {
        let result: JobResult = .init(
            status: .systemFailed,
            actions: ["provision failed"],
            stoppedAt: .wallClock,
            needsHuman: true,
            reason: "guest 起不來"
        )
        #expect(try result.jsonData() == result.jsonData())
    }
}
