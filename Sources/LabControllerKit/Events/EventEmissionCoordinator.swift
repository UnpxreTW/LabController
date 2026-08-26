//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把去重政策與去重紀錄接起來的那一層：查出這批鑰匙上次送出的時刻、交閘裁決，送出成功後把紀錄寫回。
///
/// ``EventEmissionGate`` 刻意不做 I/O、``EventEmissionStore`` 刻意不做判斷，兩者之間因此留著一段
/// 「誰去查、誰去記」的空白。本型別就是那段空白——它不新增任何規則，只把兩層的呼叫順序固定下來。
///
/// **為什麼是兩個方法、而不是一個「處理這批事件」**：送出動作夾在中間，而這一層沒有對外通道、也不
/// 該憑空造一個。裁決與記錄之間留一道縫，呼叫端才放得進真正的送出，並且只在送成功之後才回來記。
///
/// ```swift
/// let decision = try await coordinator.decide(on: events, now: .now)
/// try await channel.send(decision.admitted)
/// try await coordinator.recordEmissions(from: decision, sentAt: .now)
/// ```
///
/// **順序是 at-least-once、不是 at-most-once**：先記後送在送出失敗時會留下一筆「已經送過」，那件事
/// 於是靜靜地被抑制到窗過期；先送後記則在兩步之間當掉時重送一次。重送是吵、漏送是靜默，且狀態庫的
/// 「時刻只進不退」本就容得下重放，故取後者——這與 ``EventEmissionDecision/emissionRecords(at:)``
/// 要求呼叫端給出實際送出時刻是同一個決定的兩面。
///
/// ⚠ **已知缺口：查詢與記錄之間沒有跨行程互斥。** 兩個行程同時對同一把鑰匙走完這段，兩邊都會讀到
/// 尚未更新的時刻、於是各送一次。單一 LabController 行程的部署不會遇到；要讓多行程同時出事件，得先
/// 有一層握有全域順序的東西，那不在本層。
public struct EventEmissionCoordinator: Sendable {

    /// 裁決用的閘；去重政策自其型別表查得。
    private let gate: EventEmissionGate

    /// 上次送出時刻的持久層。
    private let store: EventEmissionStore

    /// 以閘與狀態庫建立。
    public init(gate: EventEmissionGate, store: EventEmissionStore) {
        self.gate = gate
        self.store = store
    }

    /// 查出這批事件的鑰匙上次送出的時刻，據以裁決哪些該送。
    ///
    /// 只查本批用得到的鑰匙——整表讀進來會隨部署年資線性變大，而裁決一則也用不到。
    ///
    /// - Parameters:
    ///   - events: 本輪偵測到的事件，順序即偵測端給的順序。
    ///   - now: 判定基準時刻。
    /// - Returns: 該送與不該送的分野，見 ``EventEmissionDecision``。
    /// - Throws: 讀取狀態庫失敗時拋 ``EventEmissionStoreError``。**讀不到不當成「沒送過」**：那會讓
    ///   狀態庫故障表現成整批事件重發一輪，而重發本身不會有任何一處報錯。
    public func decide(on events: [DetectedEvent], now: Date) async throws -> EventEmissionDecision {
        guard !events.isEmpty else { return .init(admitted: [], withheld: []) }
        let keys: Set<EventKey> = .init(events.map(\.key))
        let lastEmissions: [EventKey: Date] = try await store.lastEmissions(of: keys)
        return gate.decide(on: events, lastEmissions: lastEmissions, now: now)
    }

    /// 把這次裁決裡實際送出的部分記回狀態庫。
    ///
    /// **在送出成功之後呼叫**——見型別說明的順序一節。整批寫在同一個交易裡，寫不進去就一筆都不進：
    /// 記到一半的批次會讓其中一部分事件被抑制、另一部分重送，而兩者都不會報錯。
    ///
    /// - Parameters:
    ///   - decision: 送出前得到的裁決。
    ///   - sentAt: 實際送出的時刻。
    /// - Throws: 寫入狀態庫失敗時拋 ``EventEmissionStoreError``。
    public func recordEmissions(from decision: EventEmissionDecision, sentAt: Date) async throws {
        try await store.recordEmissions(decision.emissionRecords(at: sentAt))
    }
}
