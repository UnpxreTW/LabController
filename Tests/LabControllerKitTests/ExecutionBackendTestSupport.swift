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

/// 全部記在記憶體裡的執行後端；命令的答案由測試預先排好。
///
/// 存在的理由有兩個：一是證明這份協議真的實作得出來（要求裡有任何一條互相打架，寫到這裡就會
/// 卡住）；二是讓協議自帶的 ``ExecutionBackend/withGuest(_:do:)`` 有得跑——那段收拾邏輯的每一
/// 條路徑都要能被驗到，尤其是工作拋出的那一條。
final class InMemoryExecutionBackend: ExecutionBackend {

    /// 一次呼叫要回什麼；沒排到的命令一律回結束碼零、兩道輸出皆空。
    struct Script: Sendable {

        /// 依命令的第一個參數對應到要回的結果。
        var results: [String: CommandResult] = [:]

        /// 焚毀時要拋的錯；不設即成功。
        var destroyError: ExecutionBackendError?
    }

    /// 後端的全部狀態；跨並行呼叫共用，故上鎖。
    private struct State {

        /// 還在的環境，依開機順序。
        var guests: [GuestSummary] = []

        /// 各環境開機時放進去的檔案。
        var injected: [GuestIdentifier: [InjectedFile]] = [:]

        /// 收到過的命令，依收到順序。
        var executed: [[String]] = []

        /// 焚毀過幾個環境。
        var destroyCount: Int = 0

        /// 下一個要發的識別碼序號。
        var nextIdentifier: Int = 1

        /// 測試排好的答案。
        var script: Script = .init()
    }

    /// 上鎖的狀態。
    private let state: Mutex<State> = .init(.init())

    /// 建立；答案表可後補。
    init(script: Script = .init()) {
        state.withLock { $0.script = script }
    }

    /// 環境的建立時刻一律用這個固定值，測試不取系統時鐘。
    static let startedAt: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 收到過的命令，依收到順序。
    var executedCommands: [[String]] {
        state.withLock { $0.executed }
    }

    /// 焚毀過幾次。
    var destroyCount: Int {
        state.withLock { $0.destroyCount }
    }

    /// 某個環境開機時被放進去的檔案；查無環境回空陣列。
    func injectedFiles(in guest: GuestIdentifier) -> [InjectedFile] {
        state.withLock { $0.injected[guest] ?? [] }
    }

    /// 發一個序號式識別碼、把規格裡的注入檔原樣記下；不模擬啟動延遲，回來時即 ``GuestState/running``。
    func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
        state.withLock { state in
            let identifier: GuestIdentifier = .init("guest-\(state.nextIdentifier)")
            state.nextIdentifier += 1
            state.guests.append(
                .init(identifier: identifier, image: specification.image, state: .running, startedAt: Self.startedAt)
            )
            state.injected[identifier] = specification.injectedFiles
            return identifier
        }
    }

    /// 記下命令、回答案表裡排好的結果；沒排到的一律回結束碼零。環境不在時拋，
    /// 而不是回一個非零結果——「沒跑成」與「跑完不是零」在協議上是兩件事。
    func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
        try state.withLock { state in
            guard state.guests.contains(where: { $0.identifier == guest }) else {
                throw ExecutionBackendError.unknownGuest(guest)
            }
            state.executed.append(command)
            guard let name: String = command.first, let result: CommandResult = state.script.results[name] else {
                return .init(command: command, exitCode: 0)
            }
            return result
        }
    }

    /// 還在的環境，依開機順序；已焚毀的不出現。
    func ps() async throws -> [GuestSummary] {
        state.withLock { $0.guests }
    }

    /// 查單一環境；查無即拋 ``ExecutionBackendError/unknownGuest(_:)``，焚毀之後走的就是這條。
    func status(of guest: GuestIdentifier) async throws -> GuestSummary {
        try state.withLock { state in
            guard let summary: GuestSummary = state.guests.first(where: { $0.identifier == guest }) else {
                throw ExecutionBackendError.unknownGuest(guest)
            }
            return summary
        }
    }

    /// 焚毀並計次；重複焚毀不拋，照協議的冪等要求。答案表排了 `destroyError` 時一律拋，
    /// 供收拾失敗的那幾條路徑用。
    func destroy(_ guest: GuestIdentifier) async throws {
        try state.withLock { state in
            if let error: ExecutionBackendError = state.script.destroyError { throw error }
            state.destroyCount += 1
            state.guests.removeAll { $0.identifier == guest }
            state.injected[guest] = nil
        }
    }
}

/// 測試裡用來確認「拋出去的是工作自己的錯」的標記。
struct ExecutionTestMarkerError: Error, Equatable {}
