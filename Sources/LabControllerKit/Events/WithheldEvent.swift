//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一則沒有被送出的事件，連同沒送出的原因。
///
/// 事件本體照原樣留著、不只留鑰匙：鑰匙只認得出「是同一件事」，查為什麼沒發時要看的是當時
/// 讀到的佐證欄，那些值只存在事件本體裡。
public struct WithheldEvent: Sendable, Equatable {

    /// 沒有被送出的那則事件。
    public let event: DetectedEvent

    /// 沒有被送出的原因。
    public let reason: EventWithholdingReason

    /// 以事件與原因建立。
    public init(event: DetectedEvent, reason: EventWithholdingReason) {
        self.event = event
        self.reason = reason
    }
}
