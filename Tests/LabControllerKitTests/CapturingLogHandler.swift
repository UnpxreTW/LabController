//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Logging

/// 把每一行紀錄交回測試手上的後端。
///
/// 紀錄的後端由組裝行程的那一端裝上，測試要斷言的則是「這一圈跑完寫出了哪幾行」——只裝在該次
/// 測試自己造的 `Logger` 上、不動整個行程的紀錄系統，平行跑的測試彼此不會收到對方的行。
internal struct CapturingLogHandler: LogHandler {

    /// 每收到一行就呼叫一次；等級與訊息本體都交出去，要斷言哪一項由測試自己決定。
    internal let record: @Sendable (Logger.Level, String) -> Void

    /// 隨紀錄一起帶出去的欄位；測試不斷言這些，維持空的即可。
    internal var metadata: Logger.Metadata = [:]

    /// 門檻放到最低：測試要看的是實際送出的每一行，不是預設門檻篩剩的那些。
    internal var logLevel: Logger.Level = .trace

    /// 造一個把每一行交給 `record` 的 `Logger`。
    ///
    /// - Parameter record: 收行的出口，由呼叫端把行留在自己的緩衝裡。
    /// - Returns: 只走這個出口的 `Logger`。
    internal static func logger(record: @escaping @Sendable (Logger.Level, String) -> Void) -> Logger {
        Logger(label: "test") { _ in CapturingLogHandler(record: record) }
    }

    /// 逐欄存取隨紀錄帶出的欄位。
    internal subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// 只留等級與訊息本體：來源位置由紀錄系統填、不是被測那一層寫的內容。
    internal func log(event: LogEvent) {
        record(event.level, event.message.description)
    }
}
