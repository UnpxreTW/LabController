//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把一行請求送到 nymph daemon、把一行回應拿回來。
///
/// **介面收在「一行換一行」這個層次**：協議本身就是一條連線送一則請求、收一則回應，分幀靠
/// 換行。介面若收得更高（例如直接收請求型別），假傳輸就得自己解一次 JSON 才知道被問了什麼，
/// 於是測試驗的是兩份各自寫的解碼實作互相同意；收在位元組這一層，測試斷言的就是真正要送出去
/// 的那一行。
///
/// **一次呼叫等於一條連線**：對面的實作是連上、寫一行、讀一行、關掉。不做連線重用——這條線
/// 上的請求量以「開一台機器」為單位，重用省下的握手成本，換來的是要自己處理半死的連線。
public protocol NymphTransport: Sendable {

    /// 送出一行請求，回傳一行回應。
    ///
    /// - Parameter requestLine: 一則請求的 JSON，**不含結尾換行**；由實作補上。
    /// - Returns: 一則回應的 JSON，**不含結尾換行**。
    /// - Throws: ``NymphTransportError``。
    func exchange(_ requestLine: Data) async throws -> Data
}
