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

private final class DecisionRecordTests {

    /// 建事件與紀錄共用的固定時刻。
    private let at: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 自偵測到的事件建決策紀錄：鑰匙、型別、專案、佐證都直接取自事件。
    @Test
    func `builds a decision record from a detected event`() throws {
        let type: EventType = try #require(.init(rawValue: "mr_outdated"))
        let event: DetectedEvent = .init(
            type: type,
            project: "group/project",
            target: .mergeRequest(iid: 42),
            discriminators: ["abc123"],
            detectedAt: at,
            inputs: ["labels": "ci"]
        )
        let record: DecisionRecord = .init(
            decisionOn: event,
            disposition: .dispatched,
            reason: "behind target",
            decidedAt: at
        )
        #expect(record.eventKey == event.key.rawValue)
        #expect(record.eventType == "mr_outdated")
        #expect(record.project == "group/project")
        #expect(record.disposition == .dispatched)
        #expect(record.reason == "behind target")
        #expect(record.inputs == ["labels": "ci"])
        #expect(record.schemaVersion == DecisionLogEntry.schemaVersion)
    }

    /// 佐證欄承接事件的 inputs、原樣不動——與 `DetectedEvent` 的「身分與佐證分家」一致。
    @Test
    func `carries event inputs as evidence unchanged`() throws {
        let type: EventType = try #require(.init(rawValue: "issue_triage"))
        let event: DetectedEvent = .init(
            type: type,
            project: "group/project",
            target: .issue(iid: 3),
            detectedAt: at,
            inputs: ["assignee": "someone", "labels": "bug,urgent"]
        )
        let record: DecisionRecord = .init(
            decisionOn: event,
            disposition: .skipped,
            reason: "throttled",
            decidedAt: at
        )
        #expect(record.inputs == ["assignee": "someone", "labels": "bug,urgent"])
    }
}
