//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一件 job 的回寫座標：要回報到哪個站台、哪個 job、用哪把鑰匙。
///
/// 三個欄位一起才有意義，所以綁成一個型別而不是三個參數散在呼叫端——回寫要送好幾次
/// （trace 一段一段、終態可能重送），每次都重打三個參數，遲早會有一次把別的 job 的
/// token 配上這個 job 的編號，而那種錯的症狀是「回報寫到另一件 job 上」。
///
/// ⚠️ ``token`` 是 job 專屬 token、**不是** runner 認證 token：前者由站台在指派 job 時發、
/// 只對這一件 job 有效；後者用來領 job。混用即為權限錯置。
public struct JobReportTarget: Sendable, Equatable {

    /// 站台位址（含 scheme），結尾有無斜線皆可。
    public let host: String

    /// 站台端的 job 編號。
    public let identifier: Int

    /// 這一件 job 專屬的 token。
    public let token: String

    /// 逐欄建立。
    ///
    /// - Parameters:
    ///   - host: 站台位址。
    ///   - identifier: job 編號。
    ///   - token: job 專屬 token。
    public init(host: String, identifier: Int, token: String) {
        self.host = host
        self.identifier = identifier
        self.token = token
    }
}
