//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization

/// 一支可以被喊停、而且喊停時會把正在等待的人叫醒的停止訊號。
///
/// 只用旗標表示停止的話，喊停與「有人發現被喊停」之間隔著整段退避等待：領件迴圈在沒有工作
/// 時會退開 ``JobPollingLoop/Configuration/retryInterval`` 秒，那段等待期間旗標翻了也沒人看，
/// 行程要等睡滿才結束。服務管理器給的收工寬限比那段等待短時，閒著的行程每一次停止都以逾時
/// 強殺收場，從來沒有一次是自己收工的。
///
/// 本型別把「旗標」與「等待」接在一起：``stop()`` 除了翻旗標，還會把此刻停在 ``wait(_:)``
/// 裡的等待逐一取消。取消**只落在那些等待自己另開的 Task 上**，不會傳進呼叫端——正在跑的
/// job 不因此被從中間丟下。
public final class StopSignal: Sendable {

    /// 旗標與此刻登記在案的等待。
    private struct State {

        /// 是否已被喊停。
        var isStopped: Bool = false

        /// 正在等待的那些 Task，以識別碼登記，等完或被取消即撤下。
        var sleepers: [UUID: Task<Void, Never>] = [:]
    }

    /// 受鎖保護的內部狀態。
    private let state: Mutex<State> = .init(.init())

    /// 建立一支尚未被喊停的訊號。
    public init() {}

    /// 是否已被喊停；領件迴圈每一輪開始前問的就是這一個。
    public var isStopped: Bool {
        state.withLock { $0.isStopped }
    }

    /// 喊停：翻旗標，並把此刻停在 ``wait(_:)`` 裡的等待全部叫醒。
    ///
    /// 可重複呼叫，也可以從訊號處理器那種非 async 的地方呼叫。
    public func stop() {
        let sleepers: [Task<Void, Never>] = state.withLock { state in
            state.isStopped = true
            let running: [Task<Void, Never>] = .init(state.sleepers.values)
            state.sleepers.removeAll()
            return running
        }
        for sleeper in sleepers { sleeper.cancel() }
    }

    /// 等指定秒數，中途被喊停就立刻回來。
    ///
    /// 已經被喊停時一秒都不等。等待本身跑在另開的一顆 Task 裡，``stop()`` 取消的是它；
    /// 呼叫端被取消時同樣叫得醒——那顆 Task 會跟著被取消，與直接 `Task.sleep` 的行為一致。
    ///
    /// - Parameter seconds: 最多等多久。
    public func wait(_ seconds: TimeInterval) async {
        guard !isStopped else { return }
        let identifier: UUID = .init()
        let sleeper: Task<Void, Never> = .init { try? await Task.sleep(for: .seconds(seconds)) }
        // 另開 Task 與登記之間可能剛好被喊停；登記在鎖內重問一次旗標，那一槍才不會落空。
        let stoppedMeanwhile: Bool = state.withLock { state in
            guard !state.isStopped else { return true }
            state.sleepers[identifier] = sleeper
            return false
        }
        if stoppedMeanwhile { sleeper.cancel() }
        // 呼叫端被取消時也要醒：等待跑在另一顆 Task 上，取消不會自己傳過去。
        await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
        state.withLock { $0.sleepers[identifier] = nil }
    }
}
