//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 組態表中一筆事件型別的定義。
public struct EventTypeDefinition: Sendable, Equatable, Codable {

    /// 此定義描述的事件型別。
    public let type: EventType

    /// 該型別的去重抑制政策。
    public let deduplication: EventDeduplicationPolicy

    /// 一句話說明；供狀態查詢介面與事件紀錄顯示，不參與任何判斷。
    public let summary: String

    /// 以顯式欄位建立。
    public init(type: EventType, deduplication: EventDeduplicationPolicy, summary: String = "") {
        self.type = type
        self.deduplication = deduplication
        self.summary = summary
    }

    /// 解碼；`summary` 整欄缺席視為空字串，其餘欄位缺席或出現未知欄位即失敗。
    ///
    /// `summary` 只接受「整欄不寫」，寫成 `null` 一律失敗——與本型別其餘欄位同一姿態：
    /// 缺席是沒打算填，明寫 `null` 多半是上游組出來的空值，不該被當成同一件事。
    ///
    /// `deduplication` 刻意不給預設值：抑制政策決定同一件事會不會被重複送出，猜錯的兩個
    /// 方向都不便宜（猜寬＝重複送出、猜嚴＝事件永久消失），寧可要求組態寫明。
    public init(from decoder: any Decoder) throws {
        try ConfigurationCodingKey.assertNoUnknownKeys(in: decoder, known: Self.knownKeys)
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(EventType.self, forKey: .type)
        self.deduplication = try container.decode(EventDeduplicationPolicy.self, forKey: .deduplication)
        self.summary = container.contains(.summary) ? try container.decode(String.self, forKey: .summary) : ""
    }

    /// 對應組態表欄位名。
    private enum CodingKeys: String, CodingKey {
        case type
        case deduplication
        case summary
    }

    /// 本型別接受的組態欄位；用來擋掉拼錯的欄位名。
    private static let knownKeys: Set<String> = [
        CodingKeys.type.rawValue,
        CodingKeys.deduplication.rawValue,
        CodingKeys.summary.rawValue
    ]
}
