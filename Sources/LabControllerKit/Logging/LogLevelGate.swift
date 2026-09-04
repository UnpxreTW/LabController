//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Logging

/// 只做一件事的中介後端：門檻改讀 ``LogLevelThreshold``，其餘原樣轉給下游。
///
/// `Logger` 每送一行之前會先問後端的 `logLevel`，所以門檻定得比 `Logger` 晚也算數——不必去
/// 管手上那顆 `Logger` 是在門檻定案之前還是之後被建出來的。`Logger` 是實值型別，門檻若存在
/// 後端自己身上，設值只會改到某一份副本。
public struct LogLevelGate: LogHandler {

    /// 真正把行寫出去的後端。
    private var downstream: any LogHandler

    /// 門檻存放處；行程本身走 ``LogLevelThreshold/shared``。
    private let threshold: LogLevelThreshold

    /// 這個行程的紀錄門檻。讀寫都落在 ``threshold`` 上。
    public var logLevel: Logger.Level {
        get { threshold.level }
        set { threshold.set(newValue) }
    }

    /// 隨紀錄一起帶出去的欄位，原樣轉給下游。
    public var metadata: Logger.Metadata {
        get { downstream.metadata }
        set { downstream.metadata = newValue }
    }

    /// 逐欄存取隨紀錄帶出的欄位，原樣轉給下游。
    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { downstream[metadataKey: key] }
        set { downstream[metadataKey: key] = newValue }
    }

    /// 以下游後端組一層門檻。
    ///
    /// - Parameters:
    ///   - downstream: 真正把行寫出去的後端。
    ///   - threshold: 門檻存放處；未給時用整個行程共用的那一份。
    public init(downstream: any LogHandler, threshold: LogLevelThreshold = .shared) {
        self.downstream = downstream
        self.threshold = threshold
    }

    /// 把一則紀錄交給下游。門檻已由 `Logger` 在呼叫前比對過，這裡不再判一次。
    ///
    /// - Parameter event: 要送出的事件。
    public func log(event: LogEvent) {
        downstream.log(event: event)
    }
}
