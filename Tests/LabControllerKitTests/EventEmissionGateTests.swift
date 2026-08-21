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

private final class EventEmissionGateTests {

    /// 判定基準時刻；測試全用固定時刻、不取系統時鐘。
    private let now: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 型別表內有窗的型別（五分鐘）。
    private let windowed: String = "pipeline_failed"

    /// 型別表內永久抑制的型別。
    private let permanent: String = "release_published"

    /// 從沒送過的事件照送。
    @Test
    func `admits an event that has never been emitted`() throws {
        let event: DetectedEvent = try event(type: windowed)
        let decision: EventEmissionDecision = try gate().decide(on: [event], lastEmissions: [:], now: now)
        #expect(decision.admitted == [event])
        #expect(decision.withheld.isEmpty)
    }

    /// 型別表沒有的型別一律不送，且原因指名那個型別——組態漏配要看得出來。
    @Test
    func `withholds an event whose type is not in the registry`() throws {
        let event: DetectedEvent = try event(type: "todo_pending")
        let decision: EventEmissionDecision = try gate().decide(on: [event], lastEmissions: [:], now: now)
        #expect(decision.admitted.isEmpty)
        #expect(decision.withheld == [.init(event: event, reason: .unregisteredType(event.type))])
    }

    /// 空型別表什麼都不送——沒配過表的部署全靜默。
    @Test
    func `an empty registry admits nothing`() throws {
        let event: DetectedEvent = try event(type: windowed)
        let gate: EventEmissionGate = .init(registry: .empty)
        #expect(gate.decide(on: [event], lastEmissions: [:], now: now).admitted.isEmpty)
    }

    /// permanent：送過一次之後不再送，原因帶著擋下它的那個時刻。
    @Test
    func `withholds a permanently deduplicated event that was already emitted`() throws {
        let event: DetectedEvent = try event(type: permanent)
        let lastEmittedAt: Date = now.addingTimeInterval(-86_400 * 365)
        let decision: EventEmissionDecision = try gate().decide(
            on: [event],
            lastEmissions: [event.key: lastEmittedAt],
            now: now
        )
        #expect(decision.admitted.isEmpty)
        #expect(decision.withheld == [.init(event: event, reason: .alreadyEmitted(at: lastEmittedAt))])
    }

    /// window：窗內不送、到期即送（邊界照 ``EventDeduplicationPolicy`` 的左閉右開）。
    @Test
    func `withholds inside the window and admits once it has passed`() throws {
        let event: DetectedEvent = try event(type: windowed)
        let inside: EventEmissionDecision = try gate().decide(
            on: [event],
            lastEmissions: [event.key: now.addingTimeInterval(-299)],
            now: now
        )
        let passed: EventEmissionDecision = try gate().decide(
            on: [event],
            lastEmissions: [event.key: now.addingTimeInterval(-300)],
            now: now
        )
        #expect(inside.admitted.isEmpty)
        #expect(passed.admitted == [event])
    }

    /// 同一批裡的同鑰匙事件只送一則，其餘標為被取代——逐則裁決會讓這批全部放行。
    @Test
    func `admits one event per key and supersedes the rest of the batch`() throws {
        let first: DetectedEvent = try event(type: windowed, inputs: ["status": "failed"])
        let second: DetectedEvent = try event(type: windowed, inputs: ["status": "failed", "stage": "test"])
        let decision: EventEmissionDecision = try gate().decide(on: [first, second], lastEmissions: [:], now: now)
        #expect(first.key == second.key)
        #expect(decision.admitted.count == 1)
        #expect(decision.withheld.map(\.reason) == [.supersededInBatch])
    }

    /// 同鑰匙取偵測時刻最新的那則：它的佐證欄反映的是較近一次觀測。
    @Test
    func `admits the newest detection of a repeated key`() throws {
        let older: DetectedEvent = try event(type: windowed, detectedAt: now.addingTimeInterval(-60))
        let newer: DetectedEvent = try event(type: windowed, detectedAt: now, inputs: ["stage": "build"])
        let decision: EventEmissionDecision = try gate().decide(on: [older, newer], lastEmissions: [:], now: now)
        #expect(decision.admitted == [newer])
        #expect(decision.withheld == [.init(event: older, reason: .supersededInBatch)])
    }

    /// 偵測時刻相同時取傳入順序在前者，裁決不隨排序實作而變。
    @Test
    func `keeps the first of two detections made at the same time`() throws {
        let first: DetectedEvent = try event(type: windowed, inputs: ["seen": "first"])
        let second: DetectedEvent = try event(type: windowed, inputs: ["seen": "second"])
        let decision: EventEmissionDecision = try gate().decide(on: [first, second], lastEmissions: [:], now: now)
        #expect(decision.admitted == [first])
        #expect(decision.withheld == [.init(event: second, reason: .supersededInBatch)])
    }

    /// 被取代的那些依傳入順序回報，與它們各自是何時被降級無關。
    @Test
    func `reports superseded events in the order they were given`() throws {
        let first: DetectedEvent = try event(type: windowed, detectedAt: now.addingTimeInterval(-10))
        let second: DetectedEvent = try event(type: windowed, detectedAt: now.addingTimeInterval(-50))
        let third: DetectedEvent = try event(type: windowed, detectedAt: now)
        let batch: [DetectedEvent] = [first, second, third]
        let decision: EventEmissionDecision = try gate().decide(on: batch, lastEmissions: [:], now: now)
        #expect(decision.admitted == [third])
        #expect(decision.withheld.map(\.event) == [first, second])
    }

    /// 整群被抑制時同樣依傳入順序回報。
    @Test
    func `reports a fully withheld group in the order it was given`() throws {
        let first: DetectedEvent = try event(type: windowed, detectedAt: now.addingTimeInterval(-10))
        let second: DetectedEvent = try event(type: windowed, detectedAt: now)
        let decision: EventEmissionDecision = try gate().decide(
            on: [first, second],
            lastEmissions: [first.key: now.addingTimeInterval(-10)],
            now: now
        )
        #expect(decision.admitted.isEmpty)
        #expect(decision.withheld.map(\.event) == [first, second])
    }

    /// 不同鑰匙各自裁決：一則被抑制不影響另一則。
    @Test
    func `decides each key on its own record`() throws {
        let suppressed: DetectedEvent = try event(type: windowed, target: .mergeRequest(iid: 7))
        let fresh: DetectedEvent = try event(type: windowed, target: .mergeRequest(iid: 8))
        let decision: EventEmissionDecision = try gate().decide(
            on: [suppressed, fresh],
            lastEmissions: [suppressed.key: now.addingTimeInterval(-10)],
            now: now
        )
        #expect(decision.admitted == [fresh])
        #expect(decision.withheld.map(\.event) == [suppressed])
    }

    /// 裁決結果依鑰匙首次出現的順序排列。
    @Test
    func `orders the decision by the first appearance of each key`() throws {
        let issue: DetectedEvent = try event(type: windowed, target: .issue(iid: 1))
        let pipeline: DetectedEvent = try event(type: windowed, target: .pipeline(identifier: 2))
        let project: DetectedEvent = try event(type: windowed, target: .project)
        let batch: [DetectedEvent] = [issue, pipeline, project, issue]
        let decision: EventEmissionDecision = try gate().decide(on: batch, lastEmissions: [:], now: now)
        #expect(decision.admitted == [issue, pipeline, project])
    }

    /// 空批次裁決出空結果。
    @Test
    func `an empty batch decides nothing`() throws {
        let decision: EventEmissionDecision = try gate().decide(on: [], lastEmissions: [:], now: now)
        #expect(decision.admitted.isEmpty)
        #expect(decision.withheld.isEmpty)
    }

    /// 本批用不到的既有紀錄不影響裁決。
    @Test
    func `ignores stored times for keys outside the batch`() throws {
        let batched: DetectedEvent = try event(type: windowed, target: .issue(iid: 1))
        let other: DetectedEvent = try event(type: windowed, target: .issue(iid: 2))
        let decision: EventEmissionDecision = try gate().decide(
            on: [batched],
            lastEmissions: [other.key: now],
            now: now
        )
        #expect(decision.admitted == [batched])
    }

    /// 要寫回狀態層的紀錄涵蓋且僅涵蓋送出的鑰匙，時刻用呼叫端給的送出時刻。
    @Test
    func `emission records cover exactly the admitted keys at the given time`() throws {
        let admitted: DetectedEvent = try event(type: windowed, target: .issue(iid: 1))
        let unregistered: DetectedEvent = try event(type: "todo_pending", target: .issue(iid: 2))
        let decision: EventEmissionDecision = try gate().decide(
            on: [admitted, unregistered],
            lastEmissions: [:],
            now: now
        )
        let sentAt: Date = now.addingTimeInterval(3)
        #expect(decision.emissionRecords(at: sentAt) == [admitted.key: sentAt])
    }

    /// 型別表：一個有窗型別、一個永久抑制型別。
    private func gate() throws -> EventEmissionGate {
        let registry: EventTypeRegistry = try .init(
            definitions: [
                .init(type: try type(windowed), deduplication: .window(seconds: 300)),
                .init(type: try type(permanent), deduplication: .permanent)
            ]
        )
        return .init(registry: registry)
    }

    /// 以識別字取事件型別。
    private func type(_ rawValue: String) throws -> EventType {
        try #require(EventType(rawValue: rawValue))
    }

    /// 以預設值組出測試事件；只覆寫關心的那幾欄。
    private func event(
        type rawType: String,
        target: EventTarget = .project,
        detectedAt: Date? = nil,
        inputs: [String: String] = [:]
    ) throws -> DetectedEvent {
        .init(
            type: try type(rawType),
            project: "group/project",
            target: target,
            detectedAt: detectedAt ?? now,
            inputs: inputs
        )
    }
}
