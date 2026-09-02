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

// SIGTERM／SIGINT：先關掉預設處置，改由 DispatchSource 轉成呼叫端給的停止動作。
// 回傳的 source 必須由呼叫端持有到行程結束，放掉即失去訊號處理。
private func installStopHandlers(_ handler: @escaping @Sendable () -> Void) -> [any DispatchSourceSignal] {
    _ = signal(SIGINT, SIG_IGN)
    _ = signal(SIGTERM, SIG_IGN)
    let signalQueue: DispatchQueue = .init(label: "lab-controller.signal")
    return [SIGINT, SIGTERM].map { number in
        let source: any DispatchSourceSignal = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        // 處理器在 signalQueue 上執行、非 MainActor；標 @Sendable 避免繼承頂層的 MainActor
        // 隔離，否則進入時的 executor 斷言會在非主佇列觸發 dispatch_assert_queue 崩潰。
        source.setEventHandler { @Sendable in handler() }
        source.resume()
        return source
    }
}

// 所有參數皆於啟動時由 CLI 引數注入；不讀任何設定檔。未知旗標、缺值或格式不合法由
// ArgumentParser 直接印出用法說明並以非零狀態結束行程。
let parsedCommand: any ParsableCommand
do {
    parsedCommand = try LabControllerCommand.parseAsRoot()
} catch {
    LabControllerCommand.exit(withError: error)
}

// `register` 子命令：一次性動作、完成即結束行程，不進心跳迴圈。
if let register: RegisterCommand = parsedCommand as? RegisterCommand {
    let client: RunnerRegistrationClient = .init()
    let runner: RegisteredRunner
    do {
        runner = try await client.register(
            host: register.host,
            registrationToken: register.registrationToken,
            description: register.description
        )
    } catch {
        FileHandle.standardError.write(Data("lab-controller: register failed: \(error)\n".utf8))
        exit(1)
    }
    // 認證 token 僅於註冊回應揭露一次（one-shot reveal）；先印出再驗證，
    // 驗證失敗才不會讓 token 隨行程結束流失、留下拿不回 token 的孤兒 runner。
    print("lab-controller: registered runner id=\(runner.id)")
    print("lab-controller: authentication token follows on the next line")
    print(runner.token)
    do {
        try await client.verify(host: register.host, token: runner.token)
    } catch {
        FileHandle.standardError.write(Data("lab-controller: token verification failed: \(error)\n".utf8))
        exit(1)
    }
    print("lab-controller: token verified")
    exit(0)
}

// `run` 子命令：領件迴圈，跑到收到停止訊號（或 `--once` 經手完一件）為止。
if let run: RunCommand = parsedCommand as? RunCommand {
    let runnerToken: String
    do {
        runnerToken = try RunnerTokenFile.read(atPath: run.tokenFile)
    } catch {
        FileHandle.standardError.write(Data("lab-controller: token file unusable: \(error)\n".utf8))
        exit(1)
    }
    let backend: NymphExecutionBackend = .init(
        transport: UnixSocketNymphTransport(socketPath: run.resolvedSocketPath),
        configuration: run.backendConfiguration
    )
    // 停止訊號同時當旗標與等待的鬧鐘：兩輪之間的退避有三十秒，只翻旗標的話喊停要等睡滿才被
    // 讀到，服務管理器的收工寬限比那段等待短時，閒著的行程每次停止都以逾時強殺收場。取消只
    // 落在退避那顆另開的 Task 上、不碰正在跑的 job。訊號只接在兩輪之間的退避上——回寫重送前
    // 的等待是另一支、照樣睡滿，那一段提早醒等於對著仍在故障的站台立刻重送。
    let stopSignal: StopSignal = .init()
    let loop: JobPollingLoop = .init(
        backend: backend,
        configuration: .init(host: run.host, runnerToken: runnerToken, image: run.image),
        wait: { seconds in await stopSignal.wait(seconds) }
    )
    let sources: [any DispatchSourceSignal] = installStopHandlers { stopSignal.stop() }
    // 站台位址只印 scheme／host／port：`--host` 收得下 `https://oauth2:<token>@…` 這種形狀，
    // 原樣印出等於把憑證寫進行程的第一行 stdout。
    let safeHost: String = GitLabAPIError.safeLocation(of: run.host)
    print("lab-controller: polling \(safeHost) guest=\(run.os.rawValue) image=\(run.golden)")
    await loop.run(
        stopAfterFirstJob: run.once,
        isStopped: { stopSignal.isStopped },
        log: { print("lab-controller: \($0)") }
    )
    withExtendedLifetime(sources) {}
    print("lab-controller: stopped")
    exit(0)
}

// 其他內建子命令（如 `help`、`--help` 解析出的 HelpCommand）：交回 ArgumentParser 執行後結束行程。
guard let command: LabControllerCommand = parsedCommand as? LabControllerCommand else {
    do {
        var builtin: any ParsableCommand = parsedCommand
        try builtin.run()
        exit(0)
    } catch {
        LabControllerCommand.exit(withError: error)
    }
}
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

// SIGTERM／SIGINT：轉成停止旗標＋取消心跳。
let signalSources: [any DispatchSourceSignal] = installStopHandlers {
    stopRequested.store(true, ordering: .relaxed)
    heartbeat.cancel()
}

await heartbeat.value
withExtendedLifetime(signalSources) {}
print("lab-controller: stopped")
exit(0)
