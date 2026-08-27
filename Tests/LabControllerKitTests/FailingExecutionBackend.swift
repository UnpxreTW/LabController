//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Synchronization

/// 環境開得起來、但每一道命令都送不進去的後端。
final class FailingExecutionBackend: ExecutionBackend {

    /// 焚毀過幾次；用來驗環境沒有被留在那裡。
    private let destroyed: Mutex<Int> = .init(0)

    /// 焚毀次數。
    var destroyCount: Int {
        destroyed.withLock { $0 }
    }

    /// 照常發一個識別碼。
    func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
        .init("guest-1")
    }

    /// 一律以「送不進去」失敗。
    func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
        throw ExecutionBackendError.backendUnavailable(detail: "socket closed")
    }

    /// 沒有環境可列。
    func ps() async throws -> [GuestSummary] {
        []
    }

    /// 一律查無。
    func status(of guest: GuestIdentifier) async throws -> GuestSummary {
        throw ExecutionBackendError.unknownGuest(guest)
    }

    /// 計次。
    func destroy(_ guest: GuestIdentifier) async throws {
        destroyed.withLock { $0 += 1 }
    }
}
