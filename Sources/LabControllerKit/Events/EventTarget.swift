//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 事件指向的站台物件座標；與專案識別分開放，因為同一專案下可以有多個目標。
///
/// 這裡刻意是封閉集合而非字串：站台的物件種類是固定的，封閉集合讓 ``EventKey`` 的推導有
/// 可證明的唯一性（見 ``keySegments``）。事件**型別**才是隨規章而變、需要組態驅動的那一軸。
public enum EventTarget: Sendable, Hashable {

    /// 專案本身。
    case project

    /// 專案下的某個 merge request。
    case mergeRequest(iid: Int)

    /// 專案下的某個 issue。
    case issue(iid: Int)

    /// 某條 pipeline。
    case pipeline(identifier: Int)

    /// 目標的種類；鑰匙裡的種類標籤一律由這裡產出。
    ///
    /// 標籤集中在這個 raw value 列舉裡，是為了讓「標籤兩兩相異」由編譯器擔保——重複的
    /// raw value 編不過。
    ///
    /// ⚠ 編譯器擔保到此為止：它**不會**擋「兩個 ``EventTarget`` case 共用同一個種類」。
    /// 新增 case 時 ``kind`` 的窮盡 switch 只逼你回傳某一個既有種類，不逼你新增一個——
    /// 若把新的 `epic(iid:)` 對到 `.issue`，`epic(iid: 5)` 與 `issue(iid: 5)` 會編出同一把
    /// 鑰匙，其中一件事就此被當成重複丟掉。**一個 case 一個種類**是人守的不變量。
    public enum Kind: String, Sendable, CaseIterable {

        /// 專案本身。
        case project

        /// merge request。
        case mergeRequest = "merge_request"

        /// issue。
        case issue

        /// pipeline。
        case pipeline
    }

    /// 此目標屬於哪一種。
    public var kind: Kind {
        switch self {
        case .project:
            return .project
        case .mergeRequest:
            return .mergeRequest
        case .issue:
            return .issue
        case .pipeline:
            return .pipeline
        }
    }

    /// 參與去重鑰匙推導的定位段：第一段是種類標籤，其後是該種類的定位值。
    ///
    /// 每個種類標籤的後續段數固定，因此整串段序列在串接後仍可被無歧義切回——這是
    /// ``EventKey`` 能保證「不同事件必得不同鑰匙」的兩個前提之一（另一個是逐段轉義）。
    /// ⚠ 新增種類時必須同時維持兩個不變量，兩個都是人守的、編譯器不管：
    /// **段數是種類的函數**（同一個標籤不得有時帶一個定位值、有時帶兩個），以及
    /// **種類是 case 的單射**（兩個 case 共用一個種類，就等於宣告它們是同一件事）。
    public var keySegments: [String] {
        switch self {
        case .project:
            return [kind.rawValue]
        case let .mergeRequest(iid):
            return [kind.rawValue, String(iid)]
        case let .issue(iid):
            return [kind.rawValue, String(iid)]
        case let .pipeline(identifier):
            return [kind.rawValue, String(identifier)]
        }
    }
}
