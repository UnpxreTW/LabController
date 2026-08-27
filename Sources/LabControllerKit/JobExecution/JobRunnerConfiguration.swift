//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 跑一件 job 時，屬於本機而不是 payload 的那幾件設定。
///
/// **與 ``JobPlan`` 的分野是「誰說了算」**：payload 說的是這個 job 要做什麼，這裡說的是本機
/// 怎麼跑它。兩者混在一起時，站台端的 CI 檔就有機會左右本機的執行方式，而那正是逾時上限
/// 要夾在執行端的同一個理由（見 ``JobTimeoutPolicy``）。
public struct JobRunnerConfiguration: Sendable, Equatable {

    /// 未另行指定時的工作根。
    ///
    /// 取 `/tmp` 底下的固定目錄：兩種平台都有、且**環境是一次性的**——注入檔與取回的程式碼
    /// 隨環境焚毀，不需要也不應該落在會留下來的位置。
    public static let defaultWorkspaceRoot: String = "/tmp/labcontroller"

    /// 未另行指定時跑腳本用的命令。
    ///
    /// 走**登入 shell**（`-l`）：本機的工具鏈多半是靠 profile 掛上 `PATH` 的（版本管理器、
    /// 套件管理器裝的東西都是），非登入 shell 起來的環境裡它們不在路徑上，而症狀是「命令
    /// 找不到」——那會被讀成 job 自己的問題，實際上是這一行決定的。
    public static let defaultShell: [String] = ["/bin/bash", "-l"]

    /// 執行環境內的工作根；注入檔與取回的程式碼都掛在它底下。
    public let workspaceRoot: String

    /// 跑腳本用的命令與其固定參數；腳本路徑接在最後一個參數。
    public let shell: [String]

    /// 逐欄建立；兩欄各有預設值。
    public init(workspaceRoot: String = Self.defaultWorkspaceRoot, shell: [String] = Self.defaultShell) {
        self.workspaceRoot = workspaceRoot
        self.shell = shell
    }
}
