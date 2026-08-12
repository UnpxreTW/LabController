//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 決策引擎在一輪偵測裡對一則事件下的處置紀錄。
///
/// 這是決策日誌兩種行之一（另一種是 ``JobRecord``）：每輪對每則偵測到的事件記下處置與
/// 原因，事故取證以此加站台終態還原「當時為什麼這樣決定」。
///
/// **事件以鑰匙字串引用、不內嵌整個事件**：``eventKey`` 存 ``EventKey/rawValue``，讓一則事件
/// 在偵測、決策、job 三處日誌裡用同一個字串串起來；佐證欄（``inputs``）只留判定當下讀到的
/// 原始值供事後查證，與 ``DetectedEvent`` 的「身分與佐證分家」同一套設計。
public struct DecisionRecord: Sendable, Equatable, Codable {

    /// 日誌格式版本；與 ``DecisionLogEntry/schemaVersion`` 同源。
    ///
    /// 每一行都自帶版本，落在持久層的舊行才看得出是哪一代編碼規則——否則換代只會表現成
    /// 「舊日誌莫名解不回來」，沒有地方查得出原因（與 ``EventKey`` 的版本段同理）。
    public let schemaVersion: String

    /// 下決策的時刻。
    public let decidedAt: Date

    /// 事件去重鑰匙字串（``EventKey/rawValue``）；跨三種日誌行串同一件事用。
    public let eventKey: String

    /// 事件型別的 raw value（如 `mr_outdated`）；免去查鑰匙才知型別。
    public let eventType: String

    /// 專案識別。
    public let project: String

    /// 本輪對此事件下的處置。
    public let disposition: DecisionDisposition

    /// 下此處置的原因（人可讀）——`skipped` 尤其要記清楚是去重、節流還是規章判定。
    public let reason: String

    /// 判定當下讀到的原始佐證值；只供事後查證，不參與任何判斷。
    ///
    /// ⚠ 這裡承接 ``DetectedEvent/inputs``——偵測端不得把憑證或 masked 變數放進佐證，遮蔽是
    /// 上游的責任；此欄不做二次遮蔽。
    public let inputs: [String: String]

    /// 以顯式欄位建立。
    public init(
        schemaVersion: String = DecisionLogEntry.schemaVersion,
        decidedAt: Date,
        eventKey: String,
        eventType: String,
        project: String,
        disposition: DecisionDisposition,
        reason: String,
        inputs: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.decidedAt = decidedAt
        self.eventKey = eventKey
        self.eventType = eventType
        self.project = project
        self.disposition = disposition
        self.reason = reason
        self.inputs = inputs
    }

    /// 自一則偵測到的事件與處置建立；鑰匙、型別、專案、佐證直接取自事件。
    public init(
        decisionOn event: DetectedEvent,
        disposition: DecisionDisposition,
        reason: String,
        decidedAt: Date
    ) {
        self.init(
            decidedAt: decidedAt,
            eventKey: event.key.rawValue,
            eventType: event.type.rawValue,
            project: event.project,
            disposition: disposition,
            reason: reason,
            inputs: event.inputs
        )
    }
}
