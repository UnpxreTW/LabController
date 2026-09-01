//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一件已經經手完的 job，結果送不回站台。
///
/// 與「領件失敗」分開成兩個型別，是因為兩者的下一步相反：領不到件表示這一輪什麼都沒發生，
/// 退開再敲即可；回寫失敗表示這台機器**已經跑過**那件 job，站台端卻仍看著它在執行中——這時
/// 再領第二件會讓同一台機器上疊兩件工作，`--once` 也會失去「經手一件即收工」的意思。
///
/// 帶著 job 識別碼，讓收下這個錯的一側知道是哪一件卡在半途，紀錄與事後追查才有座標。
public struct JobDeliveryFailure: Error {

    /// 已經經手、但結果沒送出去的那件 job。
    public let jobIdentifier: Int

    /// 回寫時實際發生的錯（協議層或傳輸層）。
    public let cause: any Error

    /// 逐欄建立。
    ///
    /// - Parameters:
    ///   - jobIdentifier: 已經手的那件 job。
    ///   - cause: 回寫時實際發生的錯。
    public init(jobIdentifier: Int, cause: any Error) {
        self.jobIdentifier = jobIdentifier
        self.cause = cause
    }
}
