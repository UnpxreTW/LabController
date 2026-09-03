//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Testing

/// 等待被叫醒才算數的上限：真的睡滿的話會是好幾十秒，差距大到不必卡在毫秒級。
private let wakeUpBudget: TimeInterval = 5

private final class StopSignalTests {

    /// 喊停之後的等待一秒都不等。
    @Test
    func `does not wait at all once stopped`() async throws {
        let signal: StopSignal = .init()
        signal.stop()
        #expect(signal.isStopped)
        let startedAt: Date = .init()
        await signal.wait(600)
        #expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
    }

    /// 等待途中喊停會把它叫醒，不必等睡滿。
    @Test
    func `wakes a wait that is already in flight`() async throws {
        let signal: StopSignal = .init()
        let startedAt: Date = .init()
        async let waited: Void = signal.wait(600)
        // 讓上面那段等待先真的進到睡眠裡，喊停才是「途中」而不是「開始前」。
        try await Task.sleep(for: .milliseconds(50))
        signal.stop()
        await waited
        #expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
    }

    /// 沒被喊停就照樣等：叫醒的是喊停，不是每次呼叫都立刻回來。
    @Test
    func `still waits while nobody has called stop`() async throws {
        let signal: StopSignal = .init()
        let startedAt: Date = .init()
        await signal.wait(0.2)
        #expect(Date().timeIntervalSince(startedAt) >= 0.2)
        #expect(!signal.isStopped)
    }

    /// 呼叫端被取消時等待也要醒：等待跑在另一顆 Task 上，取消不會自己傳過去。
    @Test
    func `wakes when the caller itself is cancelled`() async throws {
        let signal: StopSignal = .init()
        let startedAt: Date = .init()
        let waiting: Task<Void, Never> = .init { await signal.wait(600) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await waiting.value
        #expect(Date().timeIntervalSince(startedAt) < wakeUpBudget)
        // 取消的是呼叫端、不是喊停：旗標照舊沒翻。
        #expect(!signal.isStopped)
    }

    /// 旗標一開始是關的，喊停後翻起來，重複喊停不出事。
    @Test
    func `flips the flag and tolerates repeated stops`() async throws {
        let signal: StopSignal = .init()
        #expect(!signal.isStopped)
        signal.stop()
        signal.stop()
        #expect(signal.isStopped)
    }
}
