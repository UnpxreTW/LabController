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
import Logging
import Synchronization

// 紀錄一律走 stderr、且逐行送出：以檔案承接輸出時，stdout 是整塊緩衝的，行程被強制收工時
// 那一塊從來沒有機會寫出去，檔案於是恆為空。後端只在這裡裝一次，函式庫那一層只拿 `Logger`。
// 門檻另外經一層 `LogLevelGate`：後端只能裝一次、且要在第一行紀錄送出之前，而門檻要等引數
// 解析完才知道，兩件事的時序拆不到同一刻。下游那份門檻開到底，過濾一律由 gate 做、免得兩層
// 各擋各的。
LoggingSystem.bootstrap { label in
    var stream: StreamLogHandler = .standardError(label: label)
    stream.logLevel = .trace
    return LogLevelGate(downstream: stream)
}

/// 這個行程的紀錄出口；子命令共用同一個標籤。
private let logger: Logger = .init(label: "lab-controller")

/// 把子命令收到的 `--log-level`（或 `LOG_LEVEL`）套進這個行程的紀錄門檻。
///
/// 套用擺在解析之後的分派點、不擺在 `validate()`：解析本身於是不動任何行程狀態。
///
/// - Parameter options: 該子命令解析出來的紀錄選項。
private func applyLogLevel(_ options: LoggingOptions) {
    if let warning: String = options.apply() {
        logger.warning("\(warning)")
    }
}

/// 把一行給操作者看的資料寫進 stdout。
///
/// 註冊回應揭露的 runner id 與 token 走這裡、與紀錄分流：那三行是要被人複製走的內容，混進帶
/// 時間戳與標籤的紀錄行裡就不再是可直接取用的形狀。
///
/// 寫入失敗（例如接收端已關閉、broken pipe）時拋出而非中止行程：非拋出版的 `FileHandle.write(_:)`
/// 會把寫入錯誤轉成無法攔截的 Objective-C 例外、直接讓行程崩潰；改用拋出版讓呼叫端記錄後乾淨結束。
///
/// - Parameter line: 要寫出去的內容；換行由這裡補上。
/// - Throws: 寫入失敗時拋出底層檔案錯誤。
private func writeStandardOutput(_ line: String) throws {
    try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
}

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
    applyLogLevel(register.logging)
    let client: RunnerRegistrationClient = .init()
    let runner: RegisteredRunner
    do {
        runner = try await client.register(
            host: register.host,
            registrationToken: register.registrationToken,
            description: register.description
        )
    } catch {
        logger.error("register failed: \(GitLabAPIError.safeDescription(of: error))")
        exit(1)
    }
    // 認證 token 僅於註冊回應揭露一次（one-shot reveal）；先印出再驗證，
    // 驗證失敗才不會讓 token 隨行程結束流失、留下拿不回 token 的孤兒 runner。
    do {
        try writeStandardOutput("registered runner id=\(runner.id)")
        try writeStandardOutput("authentication token follows on the next line")
        try writeStandardOutput(runner.token)
    } catch {
        logger.error("failed to write registration output: \(GitLabAPIError.safeDescription(of: error))")
        exit(1)
    }
    do {
        try await client.verify(host: register.host, token: runner.token)
    } catch {
        logger.error("token verification failed: \(GitLabAPIError.safeDescription(of: error))")
        exit(1)
    }
    logger.info("token verified")
    exit(0)
}

// `run` 子命令：領件迴圈，跑到收到停止訊號（或 `--once` 經手完一件）為止。
if let run: RunCommand = parsedCommand as? RunCommand {
    applyLogLevel(run.logging)
    let runnerToken: String
    do {
        runnerToken = try RunnerTokenFile.read(atPath: run.tokenFile)
    } catch {
        logger.error("token file unusable: \(GitLabAPIError.safeDescription(of: error))")
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
    logger.info("polling \(safeHost) guest=\(run.os.rawValue) image=\(run.golden)")
    await loop.run(
        stopAfterFirstJob: run.once,
        isStopped: { stopSignal.isStopped },
        logger: logger
    )
    withExtendedLifetime(sources) {}
    logger.info("stopped")
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
applyLogLevel(command.logging)
let configuration: Config = command.resolvedConfig

logger.info("config version=\(configuration.version) intervalSeconds=\(configuration.poll.intervalSeconds)")

// 停止旗標：訊號處理器設為 true，心跳迴圈據此結束。
let stopRequested: Atomic<Bool> = .init(false)

// 空週期心跳：每個週期印一行、迴圈內不做其他事。
let heartbeat: Task<Void, Never> = Task {
    while !stopRequested.load(ordering: .relaxed) {
        logger.info("tick")
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
logger.info("stopped")
exit(0)
