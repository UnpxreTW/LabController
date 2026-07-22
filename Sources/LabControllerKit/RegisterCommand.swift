//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// `register` 子命令的命令列引數；與根命令同一分層原則——本型別只負責解析、
/// 網路呼叫與行程結束留在可執行檔目標。註冊成功後 GitLab 僅在當次回應揭露
/// runner 認證 token，可執行檔會印出、由操作者自行保存（不落任何檔案）。
public struct RegisterCommand: ParsableCommand {

    public static let configuration: CommandConfiguration = .init(
        commandName: "register",
        abstract: "Register this controller as a GitLab runner and print the authentication token."
    )

    /// GitLab 站台基底網址（例如 `https://gitlab.example.com`）。
    @Option(help: "Base URL of the GitLab instance, e.g. https://gitlab.example.com.")
    public var host: String

    /// runner registration token；僅用於換取認證 token、不落任何檔案。
    @Option(help: "Runner registration token used to obtain the authentication token.")
    public var registrationToken: String

    /// 顯示於 GitLab runner 清單的描述文字；未給時由站台端預設。
    @Option(help: "Optional description shown in the GitLab runner list.")
    public var description: String?

    public init() {}
}
