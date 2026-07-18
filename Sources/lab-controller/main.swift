//
//  lab-controller
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Dispatch
import Foundation
import LabControllerKit
import Synchronization

// 所有參數皆於啟動時由 CLI 引數注入；不讀任何設定檔。未知旗標、缺值或格式不合法由
// ArgumentParser 直接印出用法說明並以非零狀態結束行程。
let command: LabControllerCommand = LabControllerCommand.parseOrExit()
let configuration: Config = command.resolvedConfig

print("lab-controller: config version=\(configuration.version) intervalSeconds=\(configuration.poll.intervalSeconds)")

// 停止旗標：訊號處理器設為 true，心跳迴圈據此結束。
let stopRequested: Atomic<Bool> = .init(false)

// 空週期心跳：每個週期印一行、迴圈內不做其他事。
let heartbeat: Task<Void, Never> = Task {
    while !stopRequested.load(ordering: .relaxed) {
        print("lab-controller: tick")
        // 取消會讓 sleep 立即拋錯、免等滿一個週期才反應停止訊號。
        do {
            try await Task.sleep(for: .seconds(configuration.poll.intervalSeconds))
        } catch {
            break
        }
    }
}

// SIGTERM／SIGINT：先關掉預設處置，改由 DispatchSource 轉成停止旗標＋取消心跳。
_ = signal(SIGINT, SIG_IGN)
_ = signal(SIGTERM, SIG_IGN)
let signalQueue: DispatchQueue = .init(label: "lab-controller.signal")
let signalSources: [any DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
    let source: any DispatchSourceSignal = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    // 處理器在 signalQueue 上執行、非 MainActor；標 @Sendable 避免繼承頂層的 MainActor
    // 隔離，否則進入時的 executor 斷言會在非主佇列觸發 dispatch_assert_queue 崩潰。
    source.setEventHandler { @Sendable in
        stopRequested.store(true, ordering: .relaxed)
        heartbeat.cancel()
    }
    source.resume()
    return source
}

await heartbeat.value
withExtendedLifetime(signalSources) {}
print("lab-controller: stopped")
exit(0)
