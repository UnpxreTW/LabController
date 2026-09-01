//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// `run` 子命令的命令列引數；與根命令同一分層原則——本型別只負責解析與換算，
/// 領件迴圈由 ``JobPollingLoop`` 跑、行程生命週期（訊號處理）留在可執行檔目標。
///
/// runner 認證 token 只從檔案讀（``tokenFile``）、不開放旗標直接給：旗標會原樣留在
/// 行程表與 shell 歷史裡，而這把 token 換得到本站台所有派給這台 runner 的工作。
public struct RunCommand: ParsableCommand {

    public static let configuration: CommandConfiguration = .init(
        commandName: "run",
        abstract: "Poll GitLab for jobs and run each one in a disposable guest."
    )

    /// GitLab 站台基底網址（例如 `https://gitlab.example.com`）。
    @Option(help: "Base URL of the GitLab instance, e.g. https://gitlab.example.com.")
    public var host: String

    /// 存放 runner 認證 token 的檔案路徑；內容前後的空白與換行會被去掉。
    @Option(help: "Path to the file holding the runner authentication token.")
    public var tokenFile: String

    /// 開執行環境要用的基底別名，由 nymph 自己解析成實際位置。
    @Option(help: "Name of the guest base image to clone for each job.")
    public var golden: String

    /// 要開哪一種 guest；**必填、無預設**，理由見 ``NymphGuestKind``。
    @Option(help: "Guest kind to spawn: mac or linux.")
    public var os: NymphGuestKind

    /// nymph 的 socket 檔路徑；未給時由 ``UnixSocketNymphTransport/defaultSocketPath(environment:)`` 解出。
    @Option(help: "Path to the nymph socket; defaults to the location nymph itself computes.")
    public var socket: String?

    /// 每台 guest 要求的 vCPU 數。
    @Option(help: "vCPUs requested for each guest.")
    public var cpus: Int = 4

    /// 每台 guest 要求的記憶體，GiB。
    ///
    /// 旗標名寫死成 `--memory-gib`：由屬性名自動推導會拆成 `--memory-gi-b`（縮寫詞全大寫的
    /// 命名慣例與自動推導對不上），而旗標名是對外介面、不該跟著內部命名慣例走。
    @Option(name: .customLong("memory-gib"), help: "Memory in GiB requested for each guest.")
    public var memoryGiB: Int = 4

    /// 等 guest 開到可以收命令的上限，秒。
    @Option(help: "Seconds to wait for a spawned guest to accept commands.")
    public var readinessTimeout: Int = 180

    /// 收下並跑完一件 job 之後就結束行程。
    ///
    /// **判準是「處理完一件」而不是「敲過一次站台」**：領件走的是 long-poll，站台端沒有工作時
    /// 會把連線 hold 住再回「此刻沒有」，敲一次就退等於絕大多數情況下什麼都沒跑就結束。
    @Flag(help: "Exit after one job has been handled instead of polling forever.")
    public var once: Bool = false

    public init() {}

    /// 由已解析的旗標值組出開 guest 用的參數。
    public var backendConfiguration: NymphBackendConfiguration {
        .init(os: os, cpus: cpus, memoryGiB: memoryGiB, readinessTimeoutSeconds: readinessTimeout)
    }

    /// 實際要連的 socket 路徑：有給就用給的，沒給就照對面那份規則自己算。
    public var resolvedSocketPath: String {
        socket ?? UnixSocketNymphTransport.defaultSocketPath()
    }

    /// 要從哪一份基底開環境。
    ///
    /// 一律是別名：主機絕對路徑那一形在 nymph 這個後端沒有對應的請求欄位，而且 CLI 收到的
    /// 是操作者當下打進來的字串——這條路徑上只給得出別名（見 ``GuestImage``）。
    public var image: GuestImage {
        .alias(golden)
    }
}
