//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 執行環境當下的狀態。
///
/// **沒有「已焚毀」這個狀態**：焚毀之後那個環境不會以任何形式出現在 ``ExecutionBackend/ps()``
/// 裡，`status` 也查不到（拋 ``ExecutionBackendError/unknownGuest(_:)``）。若把已焚毀做成一種
/// 狀態，呼叫端就得每次都記得去比對它，而漏比的那一次會拿著一個不存在的環境繼續往下跑。
public enum GuestState: String, Sendable, Equatable, CaseIterable {

    /// 已建立、還沒到可以收命令的程度。
    case starting

    /// 可以收命令。
    case running

    /// 還在、但停了；不再收命令，仍佔著資源直到被焚毀。
    case stopped
}
