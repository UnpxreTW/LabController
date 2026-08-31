//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 回寫時屬於本機、而不是屬於站台或 payload 的那幾件事。
///
/// 全部給了預設值：這些數字沒有一個是協議規定的，都是本側自己的取捨，而讓每個呼叫端各自
/// 決定只會讓「同一個站台被兩種節奏敲」變成常態。要調就整份調、不逐欄散在呼叫處。
public struct JobReportingConfiguration: Sendable, Equatable {

    /// 一次 `PATCH trace` 最多送幾個 byte。
    ///
    /// 協議沒有規定上限，但整份一次送出會在長 job 上撞到站台前面那層代理的本體上限，而那時
    /// 拿到的錯與「job 出事」長得一樣；分段之後，重同步要重送的量也跟著有界。
    ///
    /// 切點落在 byte 上、不對齊字元邊界：站台把每段原樣接起來，接完的結果與整份送出一致，
    /// 而要對齊字元就得在這一層理解編碼，換來的只是「中途看起來比較整齊」。
    public let traceChunkBytes: Int

    /// 終態最多送幾次（含第一次）。
    ///
    /// 站台回 202 的意思是「收下了、還沒寫進去，等一下再送一次」，所以重送是正常流程而不是
    /// 錯誤處理；但它不能無限——站台若一直沒把 trace 落地，這一側再敲下去也只是佔著一個
    /// 執行位，不如把「沒被確認」如實回給呼叫端，讓它決定要不要放掉這件 job。
    public let maximumUpdateAttempts: Int

    /// 站台沒給建議間隔時，兩次終態之間等多久（秒）。
    public let updateRetryInterval: TimeInterval

    /// trace 位移對不上時，最多重同步幾次。
    ///
    /// 站台在 416 裡會告訴我們它實際收到哪裡，照著續傳通常一次就對上；反覆對不上代表兩邊
    /// 對這份 log 的認知已經岔開，繼續送只是把同一段來回灌。
    public let maximumResyncAttempts: Int

    /// 逐欄建立；預設值見各欄說明。
    ///
    /// - Parameters:
    ///   - traceChunkBytes: 單次 trace 回寫的上限。
    ///   - maximumUpdateAttempts: 終態送出的次數上限。
    ///   - updateRetryInterval: 站台未建議間隔時的等待秒數。
    ///   - maximumResyncAttempts: 重同步次數上限。
    public init(
        traceChunkBytes: Int = 128 * 1024,
        maximumUpdateAttempts: Int = 5,
        updateRetryInterval: TimeInterval = 3,
        maximumResyncAttempts: Int = 3
    ) {
        self.traceChunkBytes = max(1, traceChunkBytes)
        self.maximumUpdateAttempts = max(1, maximumUpdateAttempts)
        self.updateRetryInterval = max(0, updateRetryInterval)
        self.maximumResyncAttempts = max(0, maximumResyncAttempts)
    }
}
