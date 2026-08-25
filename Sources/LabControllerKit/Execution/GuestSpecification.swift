//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 開一個執行環境要說明的事：拿哪份基底、環境起來時裡面先放好哪些檔案。
public struct GuestSpecification: Sendable, Equatable {

    /// 基底。
    public let image: GuestImage

    /// 環境開起來時就放進去的檔案，依給定順序寫入。
    ///
    /// **注入綁在開機這一刻、而不是另給一個 `inject` 動詞**：要注進去的多半是憑證，而憑證只在
    /// 受信任側的手上。少一個動詞就少一條「環境已經在跑、再把秘密送進去」的通道，也就少一處
    /// 要各自證明對方仍是原來那個環境的地方。真正要在跑到一半才產生的檔案，走
    /// ``ExecutionBackend/exec(_:in:)`` 寫——那條路徑本來就在環境裡面、也本來就有紀錄。
    ///
    /// 這些檔案的壽命與環境相同：焚毀即消失，不落主機、不進基底、不進站台變數。
    public let injectedFiles: [InjectedFile]

    /// 逐欄建立。
    public init(image: GuestImage, injectedFiles: [InjectedFile] = []) {
        self.image = image
        self.injectedFiles = injectedFiles
    }
}
