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

private final class JobSpecTests {

    /// 迴圈形工單共用的一份治理欄位；數值只為測試取用，不代表任何校正過的門檻。
    private let governance: SessionGovernance = .init(
        budget: .init(wallClockSeconds: 1800, turns: 12, llmCalls: 20),
        abortConditions: .init(noProgressTurns: 3, filesChangedWithoutGreen: 3),
        modelRoster: ["primary", "fallback"]
    )

    /// 把工單編出來再讀回去。
    private func roundTrip(_ spec: JobSpec) throws -> JobSpec {
        try .init(jsonData: spec.jsonData())
    }

    /// 讀一份手寫的工單檔。
    private func decode(_ json: String) throws -> JobSpec {
        try .init(jsonData: Data(json.utf8))
    }

    /// 跑一趟的工單不帶治理欄位，來回一趟每一欄都對得起來。
    @Test
    func `keeps every field of a batch job across a round trip`() throws {
        let spec: JobSpec = .batch(
            goal: "把分支接到目標分支最新處",
            completion: .rebasedOntoTarget(targetBranch: "main"),
            boundary: .init(allowedWrites: ["refs/heads/feature"], forbidden: [.gitLabAPI, .comments]),
            rules: [.init(name: "git-force-push", text: "rebase 後只用 --force-with-lease")]
        )
        let readBack: JobSpec = try roundTrip(spec)
        #expect(readBack == spec)
        #expect(readBack.shape == .batch)
        #expect(readBack.governance == nil)
        #expect(readBack.specVersion == JobSpec.currentVersion)
        #expect(readBack.rules.first?.text == "rebase 後只用 --force-with-lease")
    }

    /// 唯讀迴圈的邊界固定為唯讀：不收邊界參數，寫不出一份能寫東西的唯讀工單。
    @Test
    func `fixes the boundary of a read only session to write nothing`() throws {
        let spec: JobSpec = .readOnlySession(
            goal: "審這份改動",
            completion: .reviewDeliveredWithVerifiedAnchors,
            governance: governance
        )
        #expect(spec.boundary.allowedWrites.isEmpty)
        #expect(spec.boundary.writesAnything == false)
        #expect(spec.boundary.forbidden.count == JobBoundary.ForbiddenCapability.allCases.count)
        #expect(try roundTrip(spec) == spec)
    }

    /// 會寫 repo 的迴圈工單帶著治理欄位來回一趟，預算與收手條件原值保留。
    @Test
    func `keeps governance fields of a development session across a round trip`() throws {
        let spec: JobSpec = .developmentSession(
            goal: "把這張 issue 做完",
            completion: .buildProducedArtifacts(paths: ["build/app"]),
            boundary: .init(allowedWrites: ["refs/heads/issue-42"], forbidden: [.gitLabAPI]),
            governance: governance
        )
        let readBack: JobSpec = try roundTrip(spec)
        #expect(readBack == spec)
        #expect(readBack.governance == governance)
        #expect(readBack.governance?.budget.turns == 12)
        #expect(readBack.governance?.abortConditions.noProgressTurns == 3)
        #expect(readBack.governance?.modelRoster == ["primary", "fallback"])
    }

    /// 迴圈形工單缺治理欄位＝沒有盡頭的迴圈，讀回時擋下。
    @Test
    func `rejects a session job that carries no governance`() throws {
        let json: String = """
        {"specVersion":"v1","shape":"development_session","goal":"g",\
        "completion":{"kind":"test_report_parsed_with_zero_failures"},\
        "boundary":{"allowedWrites":["refs/heads/x"],"forbidden":[]},"rules":[]}
        """
        #expect(throws: JobSpec.CodingFailure.governanceMissingForSession(.developmentSession)) {
            try self.decode(json)
        }
    }

    /// 跑一趟的工單帶了治理欄位＝一組不會有人讀的門檻，讀回時擋下。
    @Test
    func `rejects a batch job that carries governance`() throws {
        let json: String = """
        {"specVersion":"v1","shape":"batch","goal":"g",\
        "completion":{"kind":"test_report_parsed_with_zero_failures"},\
        "boundary":{"allowedWrites":[],"forbidden":[]},"rules":[],\
        "governance":{"budget":{"wallClockSeconds":1,"turns":1,"llmCalls":1},\
        "abortConditions":{"noProgressTurns":1,"filesChangedWithoutGreen":1},"modelRoster":[]}}
        """
        #expect(throws: JobSpec.CodingFailure.governanceOnBatchJob) { try self.decode(json) }
    }

    /// 唯讀迴圈卻宣告了可寫的 ref：兩半互相矛盾，不猜哪一半是本意。
    @Test
    func `rejects a read only session that declares writable refs`() throws {
        let json: String = """
        {"specVersion":"v1","shape":"read_only_session","goal":"g",\
        "completion":{"kind":"review_delivered_with_verified_anchors"},\
        "boundary":{"allowedWrites":["refs/heads/x"],"forbidden":[]},"rules":[],\
        "governance":{"budget":{"wallClockSeconds":1,"turns":1,"llmCalls":1},\
        "abortConditions":{"noProgressTurns":1,"filesChangedWithoutGreen":1},"modelRoster":[]}}
        """
        #expect(throws: JobSpec.CodingFailure.readOnlySessionDeclaresWrites) { try self.decode(json) }
    }

    /// 完成判準在工單檔裡是扁平一層：`kind` 加上該種類自己的欄位。
    @Test
    func `writes the completion criteria as one flat object`() throws {
        let spec: JobSpec = .batch(
            goal: "g",
            completion: .rebasedOntoTarget(targetBranch: "main"),
            boundary: .readOnly
        )
        let json: String = try #require(String(data: spec.jsonData(), encoding: .utf8))
        #expect(json.contains("\"kind\":\"rebased_onto_target\""))
        #expect(json.contains("\"targetBranch\":\"main\""))
    }

    /// 五種完成判準各自來回一趟都保值。
    @Test
    func `keeps every kind of completion criteria across a round trip`() throws {
        let criteria: [JobCompletionCriteria] = [
            .rebasedOntoTarget(targetBranch: "release"),
            .buildProducedArtifacts(paths: ["out/a", "out/b"]),
            .testReportParsedWithZeroFailures,
            .lintWithinBaseline(maximumViolations: 7),
            .reviewDeliveredWithVerifiedAnchors,
        ]
        for criterion in criteria {
            let spec: JobSpec = .batch(goal: "g", completion: criterion, boundary: .readOnly)
            #expect(try roundTrip(spec).completion == criterion)
        }
    }

    /// 認不得的完成判準不落成預設值——讀不懂怎麼算完成的工單，唯一安全的處置是不開跑。
    @Test
    func `rejects a completion criteria kind it does not know`() throws {
        let json: String = """
        {"specVersion":"v1","shape":"batch","goal":"g","completion":{"kind":"looks_fine_to_me"},\
        "boundary":{"allowedWrites":[],"forbidden":[]},"rules":[]}
        """
        #expect(throws: (any Error).self) { try self.decode(json) }
    }

    /// 完成判準少了該種類的欄位一樣丟錯，不當成沒設。
    @Test
    func `rejects a completion criteria missing its own field`() throws {
        let json: String = """
        {"specVersion":"v1","shape":"batch","goal":"g","completion":{"kind":"rebased_onto_target"},\
        "boundary":{"allowedWrites":[],"forbidden":[]},"rules":[]}
        """
        #expect(throws: (any Error).self) { try self.decode(json) }
    }

    /// 認不得的執行形狀同樣擋下。
    @Test
    func `rejects a job shape it does not know`() throws {
        let json: String = """
        {"specVersion":"v1","shape":"interactive","goal":"g",\
        "completion":{"kind":"test_report_parsed_with_zero_failures"},\
        "boundary":{"allowedWrites":[],"forbidden":[]},"rules":[]}
        """
        #expect(throws: (any Error).self) { try self.decode(json) }
    }

    /// 同一份工單每次編出逐 byte 相同的內容——指紋要對得起來就靠這件事。
    @Test
    func `encodes the same spec to identical bytes every time`() throws {
        let spec: JobSpec = .developmentSession(
            goal: "g",
            completion: .lintWithinBaseline(maximumViolations: 3),
            boundary: .init(allowedWrites: ["refs/heads/x"], forbidden: [.comments]),
            governance: governance
        )
        #expect(try spec.jsonData() == spec.jsonData())
    }

    /// 跑一趟的工單不寫 `governance` 鍵，檔裡不留空欄。
    @Test
    func `omits the governance key for a batch job`() throws {
        let spec: JobSpec = .batch(goal: "g", completion: .testReportParsedWithZeroFailures, boundary: .readOnly)
        let json: String = try #require(String(data: spec.jsonData(), encoding: .utf8))
        #expect(json.contains("governance") == false)
    }

    /// 規格版本不是解碼閘：版本欄用來事後歸因，不用來擋舊的執行端。
    @Test
    func `reads a spec whose version differs from the current one`() throws {
        let json: String = """
        {"specVersion":"v0","shape":"batch","goal":"g",\
        "completion":{"kind":"test_report_parsed_with_zero_failures"},\
        "boundary":{"allowedWrites":[],"forbidden":[]},"rules":[]}
        """
        #expect(try decode(json).specVersion == "v0")
    }
}
