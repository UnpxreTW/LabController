//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 執行後端本身沒能把事情做成。
///
/// **與命令的結束碼是兩件事**：結束碼是命令跑完之後給的答案（見 ``CommandResult``），這裡的
/// 每一則都是「根本沒跑成」。兩者混在一起時，「lint 找到三個問題」與「環境已經不在了」會走同
/// 一條處理路徑，而後者需要的是重開環境、不是把問題貼進 trace。
///
/// 訊息面沿既有邊界：跨到不可信面（站台、MR、面板）時只放行 case 本身與通稱化訊息，主機路徑、
/// socket 位置與後端原文留在本側日誌。
public enum ExecutionBackendError: Error, Equatable, Sendable {

    /// 沒有這個執行環境；已焚毀或從來不存在。
    ///
    /// 兩者刻意不分：後端一般不留已焚毀環境的墓碑，能分得出來的那一段也只在墓碑還在的期間內
    /// 成立——寫成兩個 case 會讓呼叫端以為「不是已焚毀就是從沒開過」，而那個推論會過期。
    case unknownGuest(GuestIdentifier)

    /// 環境還在，但當下的狀態收不了命令。
    case guestNotReady(GuestIdentifier, state: GuestState)

    /// 連不上後端，或後端回了讀不懂的東西；`detail` 是給本側日誌看的。
    case backendUnavailable(detail: String)

    /// 後端明確拒絕這次請求（基底找不到、容量不足、權限不足等）；`detail` 是給本側日誌看的。
    case requestRejected(detail: String)
}
