//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 對一批偵測到的事件所做的送出裁決：哪些該送、哪些不送、不送的各是什麼原因。
///
/// **裁決不等於送出**：本型別只描述「應該怎麼做」，送出與記錄由呼叫端執行——那兩件事都會失敗，
/// 而失敗的處置（重試、放棄、告警）不是這一層能決定的。
public struct EventEmissionDecision: Sendable, Equatable {

    /// 該送出的事件，依鑰匙首次出現的順序排列。
    ///
    /// 同一把鑰匙在此至多出現一次——同批的重複已在裁決時收斂掉。
    public let admitted: [DetectedEvent]

    /// 不送出的事件與各自的原因；同樣依鑰匙首次出現的順序分群、群內維持傳入順序。
    public let withheld: [WithheldEvent]

    /// 以裁決結果建立。
    public init(admitted: [DetectedEvent], withheld: [WithheldEvent]) {
        self.admitted = admitted
        self.withheld = withheld
    }

    /// 送出成功之後要寫進去重狀態層的紀錄：每把送出過的鑰匙對應實際送出的時刻。
    ///
    /// **時刻由呼叫端在送完之後給**，本型別不自帶：裁決時刻與送出時刻之間隔著真正的送出動作，
    /// 拿裁決時刻當送出時刻，等於在還沒送之前就記下「已經送過」——送出失敗時那筆紀錄會讓抑制窗
    /// 白白開著，這件事直到窗過期都不會再送、也不會有任何一處報錯。
    ///
    /// 反過來的順序（送完才記）在送出與寫入之間當掉時會重送一次。那是刻意選的方向：重送一次是
    /// 吵，漏送一次是靜默。
    ///
    /// - Parameter sentAt: 實際送出的時刻。
    public func emissionRecords(at sentAt: Date) -> [EventKey: Date] {
        var records: [EventKey: Date] = [:]
        for event in admitted {
            records[event.key] = sentAt
        }
        return records
    }
}
