//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 決定一批偵測到的事件裡哪些該送出的閘：型別表上的去重政策，對上這些鑰匙上次送出的時刻。
///
/// **這一層只裁決、不做任何 I/O**：上次送出的時刻由呼叫端查出來一起傳進來，送出與記錄也由呼叫端
/// 執行。所以它是純函式——同樣的輸入永遠得到同樣的裁決，測得出每一條規則，而不必先擺出一個持久層
/// 或一條對外通道。去重狀態的規章與紀錄本來就分屬兩層（規章在型別表、紀錄在狀態層），閘是把兩者
/// 合起來得出結論的那個位置。
///
/// **一批一裁、而不是一則一裁**：同一輪偵測很容易對同一件事產出多則（同一個目標在不同回應裡各被
/// 讀到一次）。逐則裁決時每一則看到的都是「上次送出時刻還沒更新」的狀態，於是整批全部放行——去重
/// 在單則視角下沒有失效的跡象，要一整批一起看才擋得住。
///
/// **不認得的型別一律不送**（``EventWithholdingReason/unregisteredType(_:)``）：沒有定義就沒有
/// 去重政策，猜一個政策送出去，等於讓「組態漏配」表現成「事件照發、只是永遠不會被抑制」。公開預設的
/// 型別表是空的，所以沒配過表的部署什麼都不會發——這是刻意的靜默，不是缺陷。
public struct EventEmissionGate: Sendable {

    /// 事件型別表；每則事件的去重政策自此查得。
    private let registry: EventTypeRegistry

    /// 以型別表建立。
    public init(registry: EventTypeRegistry) {
        self.registry = registry
    }

    /// 裁決這一批事件裡哪些該送出。
    ///
    /// - Parameters:
    ///   - events: 本輪偵測到的事件，順序即偵測端給的順序。
    ///   - lastEmissions: 這些鑰匙上次送出的時刻；查無紀錄的鑰匙不必出現在裡面（缺席＝從沒送過）。
    ///     多帶了本批用不到的鑰匙不影響裁決。
    ///   - now: 判定基準時刻。
    /// - Returns: 該送與不該送的分野，見 ``EventEmissionDecision``。
    ///
    /// 政策只在真有紀錄時才問——去重政策對「從沒送過」一律不抑制
    /// （見 ``EventDeduplicationPolicy/suppressesEmission(lastEmittedAt:now:)``），沒有紀錄時問了
    /// 也是同一個答案。
    public func decide(
        on events: [DetectedEvent],
        lastEmissions: [EventKey: Date],
        now: Date
    ) -> EventEmissionDecision {
        var admitted: [DetectedEvent] = []
        var withheld: [WithheldEvent] = []
        for group in Self.grouped(events) {
            guard let definition: EventTypeDefinition = registry.definition(for: group.representative.type) else {
                let reason: EventWithholdingReason = .unregisteredType(group.representative.type)
                withheld.append(contentsOf: Self.withholding(group.members, because: reason))
                continue
            }
            let policy: EventDeduplicationPolicy = definition.deduplication
            if let lastEmittedAt: Date = lastEmissions[group.key],
               policy.suppressesEmission(lastEmittedAt: lastEmittedAt, now: now) {
                let reason: EventWithholdingReason = .alreadyEmitted(at: lastEmittedAt)
                withheld.append(contentsOf: Self.withholding(group.members, because: reason))
                continue
            }
            admitted.append(group.representative)
            withheld.append(contentsOf: Self.withholding(group.superseded, because: .supersededInBatch))
        }
        return .init(admitted: admitted, withheld: withheld)
    }

    /// 依去重鑰匙把一批事件分群；群的先後＝各鑰匙首次出現的先後。
    private static func grouped(_ events: [DetectedEvent]) -> [Group] {
        var groups: [Group] = []
        var offsetByKey: [EventKey: Int] = [:]
        for event in events {
            let key: EventKey = event.key
            guard let offset: Int = offsetByKey[key] else {
                offsetByKey[key] = groups.count
                groups.append(.init(key: key, first: event))
                continue
            }
            groups[offset].take(event)
        }
        return groups
    }

    /// 一群事件配同一個不送出的原因。
    private static func withholding(
        _ events: [DetectedEvent],
        because reason: EventWithholdingReason
    ) -> [WithheldEvent] {
        events.map { .init(event: $0, reason: reason) }
    }

    /// 同一把鑰匙的一群事件。
    ///
    /// 代表者在收件當下就決定，而不是事後排序：排序得在偵測時刻相同時另定一條決勝規則，而
    /// `sorted(by:)` 本身不保證穩定，同刻的兩則誰出線會隨實作而變。
    ///
    /// 成員一律照傳入順序留著、只另記代表者的位置。若改成把被取代者另存一份，那份的順序會是
    /// 「被降級的先後」而不是傳入順序——先收到的事件可能在一次較晚的降級之後才被放進去。
    private struct Group {

        /// 這一群共用的去重鑰匙。
        let key: EventKey

        /// 群內全部事件，依傳入順序。
        private(set) var members: [DetectedEvent]

        /// 代表者在 ``members`` 裡的位置。
        private var representativeOffset: Int

        /// 以群內首則事件開群。
        init(key: EventKey, first event: DetectedEvent) {
            self.key = key
            self.members = [event]
            self.representativeOffset = 0
        }

        /// 送出時代表這一群的那則：偵測時刻最新者，同刻取傳入順序在前者。
        var representative: DetectedEvent {
            members[representativeOffset]
        }

        /// 被代表者取代的其餘事件，依傳入順序。
        var superseded: [DetectedEvent] {
            members.enumerated().filter { $0.offset != representativeOffset }.map(\.element)
        }

        /// 收下同鑰匙的另一則事件。
        mutating func take(_ event: DetectedEvent) {
            members.append(event)
            guard event.detectedAt > representative.detectedAt else { return }
            representativeOffset = members.count - 1
        }
    }
}
