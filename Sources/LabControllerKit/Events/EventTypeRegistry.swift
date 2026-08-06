//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 事件型別表：本部署認得哪些事件型別、各自的去重政策為何。
///
/// 預設為空表（``empty``）——型別集合由部署端的組態注入，本模組只負責讀表、查表與擋掉表
/// 本身的錯誤。
public struct EventTypeRegistry: Sendable, Equatable, Codable {

    /// 表內無任何型別；未注入組態時的預設值。
    ///
    /// ⚠ 空表與「型別不在表內」在 ``definition(for:)`` 看起來一樣，都是 `nil`。組態漏載時
    /// 每一則事件都會被擋下、整批無聲消失——載入端應在 ``definitions`` 為空時明確告警一次，
    /// 別讓「沒載到」長得像「這些事件本來就不該處理」。
    public static let empty: EventTypeRegistry = .init()

    /// 依組態順序保留的定義清單；查表索引由它導出，兩者不會失步。
    public let definitions: [EventTypeDefinition]

    /// 型別到定義的查表索引。
    private let definitionsByType: [EventType: EventTypeDefinition]

    /// 以定義清單建立；同一型別出現兩次即拋 ``RegistryError/duplicateType(_:)``。
    ///
    /// 重複不採「後者覆蓋前者」：組態裡出現兩筆同名定義，代表寫的人以為自己在描述兩件事，
    /// 靜默取其一等於讓另一筆的政策憑空消失、而且沒有任何一處會提。
    public init(definitions: [EventTypeDefinition]) throws {
        var index: [EventType: EventTypeDefinition] = [:]
        for definition: EventTypeDefinition in definitions {
            guard index.updateValue(definition, forKey: definition.type) == nil else {
                throw RegistryError.duplicateType(definition.type)
            }
        }
        self.definitions = definitions
        self.definitionsByType = index
    }

    /// 建立空表；供 ``empty`` 使用。
    private init() {
        self.definitions = []
        self.definitionsByType = [:]
    }

    /// 自組態的定義陣列解碼。
    ///
    /// 表本身有錯（型別重複）時包成 `DecodingError.dataCorrupted` 再拋，讓呼叫端只需接一種
    /// 錯誤型別、也拿得到 `codingPath`；直接呼叫 ``init(definitions:)`` 的路徑仍拋
    /// ``RegistryError``。
    public init(from decoder: any Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let decoded: [EventTypeDefinition] = try container.decode([EventTypeDefinition].self)
        do {
            try self.init(definitions: decoded)
        } catch let error as RegistryError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: error.description,
                    underlyingError: error
                )
            )
        }
    }

    /// 編碼為定義陣列，順序與讀入時一致。
    public func encode(to encoder: any Encoder) throws {
        var container: SingleValueEncodingContainer = encoder.singleValueContainer()
        try container.encode(definitions)
    }

    /// 表內型別，順序與組態一致。
    public var types: [EventType] {
        definitions.map(\.type)
    }

    /// 查表。
    ///
    /// **查無屬正常路徑**（偵測端送來表外的型別），故回 optional。⚠ 呼叫端不得把 `nil`
    /// 當成「套個預設政策就好」——那會讓打錯字的型別名一路暢通、每輪重發一次。正確處置是
    /// 留下可追查的紀錄並擋下該事件。
    public func definition(for type: EventType) -> EventTypeDefinition? {
        definitionsByType[type]
    }

    /// 型別表本身的錯誤。
    public enum RegistryError: Error, Equatable, CustomStringConvertible, LocalizedError {

        /// 同一型別在組態中出現兩次以上。
        case duplicateType(EventType)

        /// 可直接放進錯誤訊息的說明。
        public var description: String {
            switch self {
            case let .duplicateType(type):
                return "同一事件型別在組態中出現兩次以上：\"\(type.rawValue)\""
            }
        }

        /// 同 ``description``；沒有它的話 `localizedDescription` 只會回一句沒有內容的預設訊息。
        public var errorDescription: String? {
            description
        }
    }
}
