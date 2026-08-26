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

private final class EventEmissionCoordinatorTests {

    /// 本次測試的暫存目錄；每個實例一個，測試之間不共用檔案。
    private let directory: URL

    /// 判定基準時刻；需要「較早／較晚」時以此加減。
    private let now: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 型別表內有窗的型別（五分鐘）。
    private let windowed: String = "pipeline_failed"

    /// 建暫存目錄。
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventEmissionCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 收掉暫存目錄；清不掉也不讓測試失敗（清理失敗不是被測行為）。
    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 空的狀態庫上，沒送過的事件照送。
    @Test
    func `admits an event that the store has never seen`() async throws {
        let coordinator: EventEmissionCoordinator = try coordinator()
        let event: DetectedEvent = try event(target: .issue(iid: 1))
        let decision: EventEmissionDecision = try await coordinator.decide(on: [event], now: now)
        #expect(decision.admitted == [event])
        #expect(decision.withheld.isEmpty)
    }

    /// 送出後把紀錄寫回去，同一件事在窗內就不再送——這一條走完整條環，是本層存在的理由。
    @Test
    func `withholds the same event after the emission has been recorded`() async throws {
        let coordinator: EventEmissionCoordinator = try coordinator()
        let event: DetectedEvent = try event(target: .issue(iid: 1))
        let first: EventEmissionDecision = try await coordinator.decide(on: [event], now: now)
        try await coordinator.recordEmissions(from: first, sentAt: now)
        let second: EventEmissionDecision = try await coordinator.decide(on: [event], now: now.addingTimeInterval(60))
        #expect(second.admitted.isEmpty)
        #expect(second.withheld == [.init(event: event, reason: .alreadyEmitted(at: now))])
    }

    /// 窗過了就再送一次——抑制是有期限的，不是一送定終身。
    @Test
    func `admits the event again once the window has passed`() async throws {
        let coordinator: EventEmissionCoordinator = try coordinator()
        let event: DetectedEvent = try event(target: .issue(iid: 1))
        let first: EventEmissionDecision = try await coordinator.decide(on: [event], now: now)
        try await coordinator.recordEmissions(from: first, sentAt: now)
        let later: Date = now.addingTimeInterval(301)
        #expect(try await coordinator.decide(on: [event], now: later).admitted == [event])
    }

    /// 記回去的時刻是呼叫端給的送出時刻，不是裁決時刻。
    @Test
    func `records the time the caller says the emission happened`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let coordinator: EventEmissionCoordinator = try coordinator(store: store)
        let event: DetectedEvent = try event(target: .mergeRequest(iid: 7))
        let decision: EventEmissionDecision = try await coordinator.decide(on: [event], now: now)
        let sentAt: Date = now.addingTimeInterval(12)
        try await coordinator.recordEmissions(from: decision, sentAt: sentAt)
        #expect(try await store.lastEmission(of: event.key) == sentAt)
    }

    /// 沒被放行的事件不留紀錄——不然它會被自己從沒送出的那一次擋住。
    @Test
    func `records nothing for events that were withheld`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let coordinator: EventEmissionCoordinator = try coordinator(store: store)
        let unregistered: DetectedEvent = try event(type: "todo_pending", target: .issue(iid: 1))
        let decision: EventEmissionDecision = try await coordinator.decide(on: [unregistered], now: now)
        #expect(decision.admitted.isEmpty)
        try await coordinator.recordEmissions(from: decision, sentAt: now)
        #expect(try await store.lastEmission(of: unregistered.key) == nil)
    }

    /// 同批同一把鑰匙的多則只送一則、也只記一筆。
    @Test
    func `records one time per key for a batch that repeats the same key`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let coordinator: EventEmissionCoordinator = try coordinator(store: store)
        let earlier: DetectedEvent = try event(target: .issue(iid: 1), detectedAt: now.addingTimeInterval(-30))
        let latest: DetectedEvent = try event(target: .issue(iid: 1), detectedAt: now)
        let decision: EventEmissionDecision = try await coordinator.decide(on: [earlier, latest], now: now)
        #expect(decision.admitted == [latest])
        try await coordinator.recordEmissions(from: decision, sentAt: now)
        #expect(try await store.lastEmission(of: latest.key) == now)
    }

    /// 狀態庫裡別把鑰匙的紀錄不影響本批——只查本批用得到的鑰匙。
    @Test
    func `ignores recorded times for keys outside the batch`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let coordinator: EventEmissionCoordinator = try coordinator(store: store)
        let other: DetectedEvent = try event(target: .issue(iid: 2))
        try await store.recordEmission(of: other.key, at: now)
        let batched: DetectedEvent = try event(target: .issue(iid: 1))
        #expect(try await coordinator.decide(on: [batched], now: now).admitted == [batched])
    }

    /// 空批次裁決出空結果。
    @Test
    func `decides nothing for an empty batch`() async throws {
        let decision: EventEmissionDecision = try await coordinator().decide(on: [], now: now)
        #expect(decision.admitted.isEmpty)
        #expect(decision.withheld.isEmpty)
    }

    /// 全數被擋下時不寫任何東西——空的紀錄不開交易，也不該留下痕跡。
    @Test
    func `writes nothing when the decision admitted no event`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let coordinator: EventEmissionCoordinator = try coordinator(store: store)
        let unregistered: DetectedEvent = try event(type: "todo_pending", target: .issue(iid: 1))
        let decision: EventEmissionDecision = try await coordinator.decide(on: [unregistered], now: now)
        try await coordinator.recordEmissions(from: decision, sentAt: now)
        #expect(try await store.lastEmissions(of: [unregistered.key]).isEmpty)
    }

    /// 較早的送出時刻推不回已記下的較晚時刻——重放一份舊裁決不會重新打開抑制窗。
    @Test
    func `never moves a recorded time backwards`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let coordinator: EventEmissionCoordinator = try coordinator(store: store)
        let event: DetectedEvent = try event(target: .issue(iid: 1))
        let decision: EventEmissionDecision = try await coordinator.decide(on: [event], now: now)
        try await coordinator.recordEmissions(from: decision, sentAt: now.addingTimeInterval(120))
        try await coordinator.recordEmissions(from: decision, sentAt: now)
        #expect(try await store.lastEmission(of: event.key) == now.addingTimeInterval(120))
    }

    /// 本次測試獨用的資料庫檔位置。
    private func databaseURL() -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).sqlite3")
    }

    /// 以指定的狀態庫組一個接好線的協調者；未指定時另開一個空的。
    private func coordinator(store: EventEmissionStore? = nil) throws -> EventEmissionCoordinator {
        let registry: EventTypeRegistry = try .init(
            definitions: [.init(type: try type(windowed), deduplication: .window(seconds: 300))]
        )
        return .init(gate: .init(registry: registry), store: try store ?? .init(at: databaseURL()))
    }

    /// 以識別字取事件型別。
    private func type(_ rawValue: String) throws -> EventType {
        try #require(EventType(rawValue: rawValue))
    }

    /// 以預設值組出測試事件；只覆寫關心的那幾欄。
    private func event(
        type rawType: String? = nil,
        target: EventTarget,
        detectedAt: Date? = nil
    ) throws -> DetectedEvent {
        .init(
            type: try type(rawType ?? windowed),
            project: "group/project",
            target: target,
            detectedAt: detectedAt ?? now
        )
    }
}
