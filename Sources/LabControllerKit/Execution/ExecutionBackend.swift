//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 把工作放進一個一次性執行環境裡跑，這一側只需要的五個動作。
///
/// **這份協議是本側定義的，不是任何一種後端的介面翻拍**：以隔離環境跑 CI 步驟的東西不只一種，
/// 而 LabController 對它們的要求其實很窄——開一個、在裡面跑命令、看有哪些、看某一個、關掉。
/// 只要能提供這五個動作，就接得上；換一種後端不必動任何一個呼叫端。反過來說，把某一個後端的
/// 原生介面直接當成本側型別用，那份介面的每一個細節都會沿著呼叫端擴散出去，而擴散到哪裡在
/// 換掉它之前沒有人數得清。
///
/// **不在這份協議裡的，是刻意不在的**：暫停與續跑、快照、環境之間的網路編排——本側沒有任何
/// 一條路徑用得到，先寫進來只會讓後端為了合規去實作一個沒有呼叫端的動作。要用時再加。
///
/// **檔案注入不是第六個動作**：要放進環境的檔案寫在 ``GuestSpecification/injectedFiles`` 裡、
/// 開機時就位，理由見該欄位說明。
///
/// **結束碼是資料**：``exec(_:in:)`` 只有在「命令沒跑成」時才拋（環境不在、送不進去）；命令
/// 跑完了就回 ``CommandResult``，非零結束碼在裡面。
public protocol ExecutionBackend: Sendable {

    /// 依規格開一個執行環境，回到可以收命令的程度才回。
    ///
    /// **回來時就該是 ``GuestState/running``**：把「開了但還不能用」留給呼叫端自己輪詢，等於
    /// 每一個呼叫端各寫一次同樣的等待迴圈，而寫錯的那一份會表現成偶發的第一道命令失敗。
    ///
    /// - Parameter specification: 基底與開機時要放進去的檔案。
    /// - Returns: 新環境的識別碼。
    /// - Throws: ``ExecutionBackendError``。
    func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier

    /// 在指定環境裡跑一道命令，跑完才回。
    ///
    /// 命令逐個參數給、不接受單一字串：由本側拼一條 shell 命令列，等於每個帶空白或引號的參數
    /// 都要各自記得跳脫，而漏跳脫的那一次是把一段內容當成命令執行。
    ///
    /// - Parameters:
    ///   - command: 可執行檔與其參數。
    ///   - guest: 要在哪個環境裡跑。
    /// - Returns: 結束碼與兩道輸出；非零結束碼是結果、不是錯誤。
    /// - Throws: ``ExecutionBackendError``。
    func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult

    /// 這個後端當下有哪些環境。
    ///
    /// 涵蓋**不是本行程開的**那些：本側行程重啟之後，孤兒就只剩這一條路看得到。
    ///
    /// - Returns: 各環境的當下樣子；順序由後端決定。
    /// - Throws: ``ExecutionBackendError``。
    func ps() async throws -> [GuestSummary]

    /// 查單一環境當下的樣子。
    ///
    /// - Parameter guest: 環境識別碼。
    /// - Returns: 當下樣子。
    /// - Throws: 查無此環境時拋 ``ExecutionBackendError/unknownGuest(_:)``；其餘見
    ///   ``ExecutionBackendError``。
    func status(of guest: GuestIdentifier) async throws -> GuestSummary

    /// 焚毀一個環境，連同裡面的一切。
    ///
    /// **同一個環境焚毀兩次不算錯**：第二次直接回，不拋 ``ExecutionBackendError/unknownGuest(_:)``。
    /// 收拾路徑常常被走兩次（正常收尾一次、失敗處理再一次），而「已經沒有了」正是它要的結果——
    /// 在這裡拋，只會逼每個收拾點都去接一個表示成功的例外，接漏的那一次讓真正的錯誤被蓋掉。
    ///
    /// - Parameter guest: 環境識別碼。
    /// - Throws: ``ExecutionBackendError``（連不上、後端拒絕等）。
    func destroy(_ guest: GuestIdentifier) async throws
}

public extension ExecutionBackend {

    /// 開一個環境、跑完給定的工作、無論結果如何都把它焚毀。
    ///
    /// 環境是計價的資源，而漏焚毀不會有任何徵兆——它只是留在那裡佔著格子，直到有人去看
    /// ``ps()``。把焚毀綁在這個函式裡，呼叫端就不會有「早退的那一條路徑忘了收拾」的版本。
    ///
    /// **工作拋出時，拋出去的是工作的那個錯**：焚毀若也失敗，兩個之中只能留一個，而先發生的
    /// 那個是因、收拾失敗多半是它的果。被蓋掉的收拾失敗不會就此消失——它留下的環境仍在
    /// ``ps()`` 上看得到，而回收孤兒本來就是後端那一側的事。
    ///
    /// - Parameters:
    ///   - specification: 環境規格。
    ///   - body: 拿到環境識別碼之後要做的事。
    /// - Returns: `body` 的回傳值。
    /// - Throws: `body` 拋出的錯；`body` 正常結束時，焚毀若失敗則拋焚毀的錯。
    func withGuest<Value>(
        _ specification: GuestSpecification,
        do body: (GuestIdentifier) async throws -> Value
    ) async throws -> Value {
        let guest: GuestIdentifier = try await spawn(specification)
        let value: Value
        do {
            value = try await body(guest)
        } catch {
            // `try?`：這裡失敗＝沒收拾成，而呼叫端當下要看的是工作自己的那個錯（見上方說明）；
            // 收拾失敗不會就此消失，它留下的環境仍在 `ps()` 上看得到。
            try? await destroy(guest)
            throw error
        }
        try await destroy(guest)
        return value
    }
}
