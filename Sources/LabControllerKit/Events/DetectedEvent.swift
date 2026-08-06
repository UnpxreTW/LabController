//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 偵測器產出的一則事件。
///
/// **身分與佐證分開**：`type`／`project`／`target`／`discriminators` 構成身分，去重鑰匙只由
/// 這四項推導；`inputs` 是佐證——判定當下讀到的原始值，只留作事後查證用。佐證若進了鑰匙，
/// 任何一個無關欄位變動都會讓同一件事再發一次，去重就形同虛設。
///
/// ⚠ 因此 `==` **不等於「同一件事」**：它比的是整個值、含佐證欄。判斷是不是同一件事一律
/// 走 ``key``。
public struct DetectedEvent: Sendable, Equatable {

    /// 事件型別。
    public let type: EventType

    /// 專案識別。
    ///
    /// 同一部署內必須一致（全用路徑或全用數字識別碼，不可混用）——混用會讓同一專案的同一
    /// 件事產生兩把不同的鑰匙，兩把都通過去重、於是送出兩次。
    ///
    /// ⚠ 本型別**不驗證**這個欄位：它通常直接來自站台回應，該長什麼樣由偵測端決定。代價是
    /// ``EventType`` 擋掉的那類失效（尾隨空白、隱形字元造成兩個看起來相同的值）在這裡沒有
    /// 防線——由偵測端自己負責，別把未整理的使用者輸入直接塞進來。
    public let project: String

    /// 事件指向的物件。
    public let target: EventTarget

    /// 額外區辨段：同一目標上「換了這個東西就該重新發一次」的值，例如 commit sha。
    ///
    /// 順序有意義、參與鑰匙推導。不需要額外區辨時留空。
    public let discriminators: [String]

    /// 偵測到的時刻。
    public let detectedAt: Date

    /// 判定當下讀到的原始值；供事後查證，不參與任何判斷、不進鑰匙。
    public let inputs: [String: String]

    /// 以顯式欄位建立。
    public init(
        type: EventType,
        project: String,
        target: EventTarget,
        discriminators: [String] = [],
        detectedAt: Date,
        inputs: [String: String] = [:]
    ) {
        self.type = type
        self.project = project
        self.target = target
        self.discriminators = discriminators
        self.detectedAt = detectedAt
        self.inputs = inputs
    }

    /// 此事件的去重鑰匙。
    public var key: EventKey {
        .init(of: self)
    }
}
