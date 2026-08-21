//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一則偵測到的事件沒有被送出的原因。
///
/// 「沒送出」有好幾種完全不同的意思，而它們的處置也不同：型別表漏了一個型別是**組態缺陷**、
/// 該有人去補；抑制窗內不再送是**規章生效**、正常路徑；同一批裡被較新的同鑰匙事件取代是
/// **批次內收斂**。把三者併成一個布林值，事後就分不出「規章擋下的」與「組態漏掉的」——而後者
/// 會表現成某個型別的事件永遠不發，沒有任何一處會報錯。
public enum EventWithholdingReason: Sendable, Equatable {

    /// 型別表裡沒有這個型別的定義；沒有定義就沒有去重政策可依，故不送出。
    ///
    /// 公開預設的型別表是空的（見 ``EventTypeRegistry/empty``）——沒配過表就什麼都不發，
    /// 是刻意的：漏配時寧可全靜默、也不要用一個猜出來的政策把整批事件送出去。
    case unregisteredType(EventType)

    /// 這把鑰匙已經送過，且該型別的去重政策據此判定此刻不再送。
    ///
    /// 名字不寫成「最近送過」：`permanent` 政策下擋住這則的可能是一年前那次送出，說成最近會與
    /// 事實相反。政策怎麼判是政策的事，這裡只記「依哪一筆紀錄判的」。
    ///
    /// 帶上那個時刻，是為了讓事後查得出「被什麼擋的」——只記「被抑制」的話，抑制設定改動前後的
    /// 紀錄長得一模一樣，回頭對不出當時是依哪一筆紀錄擋的。
    case alreadyEmitted(at: Date)

    /// 同一批裡有另一則同鑰匙、偵測時刻較新的事件被送出，本則由它取代。
    ///
    /// 同一把鑰匙代表同一件事，一批送兩次即為重複；取較新的那則，是因為它的佐證欄
    /// （``DetectedEvent/inputs``）反映的是較近一次觀測。
    case supersededInBatch
}
