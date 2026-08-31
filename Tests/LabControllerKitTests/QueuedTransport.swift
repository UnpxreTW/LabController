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

/// 依序播放預錄回應的假傳輸；把收到的請求原樣留下供斷言。
///
/// 全部為合成資料（假 id／token／站台位址），不含任何真實站台內容。序列耗盡後重複最後一個
/// 回應——回寫要測的是「同樣的回覆會被送幾次」，讓最後一個一直重播，測試才寫得出次數上限
/// 那類斷言而不必預先數好要準備幾份。
internal final class QueuedTransport: HTTPTransport, Sendable {

    /// 收到的請求，依序累積。
    internal let requests: Mutex<[HTTPRequest]> = .init([])

    /// 待播放的回應序列。
    private let responses: Mutex<[HTTPResponse]>

    /// 以回應序列建立。
    ///
    /// - Parameter responses: 依序播放的回應。
    internal init(_ responses: [HTTPResponse]) {
        self.responses = .init(responses)
    }

    /// 記錄請求，回覆序列中的下一個回應。
    ///
    /// - Parameter request: 送出的請求。
    /// - Returns: 序列中的下一個回應；只剩一個時重複它。
    internal func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.withLock { $0.append(request) }
        return responses.withLock { queue in
            queue.count > 1 ? queue.removeFirst() : (queue.first ?? .init(statusCode: 500))
        }
    }
}
