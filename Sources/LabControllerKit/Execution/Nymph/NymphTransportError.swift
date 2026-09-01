//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 連 nymph daemon 這條線本身出的事，還談不到工具語義。
///
/// 與 ``ExecutionBackendError`` 分層：這裡的每一則都會被後端收成
/// ``ExecutionBackendError/backendUnavailable(detail:)``，`detail` 留在本側日誌。分成兩個型別
/// 的理由是傳輸實作可以被換掉（socket 換成別的），而換掉時不該牽動本側協議的錯誤面。
public enum NymphTransportError: Error, Equatable, Sendable {

    /// socket 路徑超過作業系統對 `sun_path` 的長度上限。
    ///
    /// 單獨列一則的理由是它與「daemon 沒起來」完全不同：路徑太長時 daemon 起得再成功也連不上，
    /// 而錯誤訊息會長得像連線失敗，於是每次都從「是不是忘了開 daemon」開始查。
    case pathTooLong(path: String)

    /// 連不上；daemon 沒起來、socket 檔不在、或權限不足。
    case connectFailed(path: String, detail: String)

    /// 寫請求時連線就斷了。
    case writeFailed(detail: String)

    /// 讀到完整一行之前連線就關了。
    case connectionClosed
}
