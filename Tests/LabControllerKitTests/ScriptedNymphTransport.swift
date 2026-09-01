//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Synchronization

/// 依序播放預錄回應的假 nymph 傳輸；把送出去的每一行原樣留下供斷言。
///
/// 全部是合成資料（假識別碼、假別名），不含任何真實環境的內容。斷言留在「送出去的那一行」這個
/// 層次，測到的才是真正會上線的位元組——若改成在這裡先解回請求型別再比對欄位，測的就變成本側
/// 的編碼與本側的解碼互相同意，而兩邊一起錯的那一種錯它永遠看不到。
internal final class ScriptedNymphTransport: NymphTransport, Sendable {

    /// 送出去的每一行請求，依序累積。
    internal let requests: Mutex<[Data]> = .init([])

    /// 以回應序列建立。
    ///
    /// - Parameters:
    ///   - responses: 依序播放的回應行；只剩一個時重複播放它，好讓「同一種回覆被要了幾次」這
    ///     類斷言不必先數好要準備幾份。
    ///   - failure: 設了就一律拋，用來測連不上 daemon 的那條路徑。
    internal init(_ responses: [String], failure: NymphTransportError? = nil) {
        self.responses = .init(responses)
        self.failure = failure
    }

    /// 記錄請求，回覆序列中的下一行。
    ///
    /// - Parameter requestLine: 送出的請求行。
    /// - Returns: 序列中的下一行回應。
    /// - Throws: 建立時給了 `failure` 就拋它。
    internal func exchange(_ requestLine: Data) async throws -> Data {
        requests.withLock { $0.append(requestLine) }
        if let failure { throw failure }
        return responses.withLock { queue in
            .init((queue.count > 1 ? queue.removeFirst() : (queue.first ?? "")).utf8)
        }
    }

    /// 待播放的回應序列。
    private let responses: Mutex<[String]>

    /// 設了就一律拋的傳輸錯誤。
    private let failure: NymphTransportError?
}
