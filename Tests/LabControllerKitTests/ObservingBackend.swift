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

/// 記下開環境時被放進去哪些檔案，其餘動作原樣轉給裡面那個後端。
final class ObservingBackend: ExecutionBackend {

    /// 真正做事的後端。
    private let inner: InMemoryExecutionBackend

    /// 最近一次開環境時放進去的檔案。
    private let recorded: Mutex<[InjectedFile]> = .init([])

    /// 以裡面那個後端建立。
    init(inner: InMemoryExecutionBackend) {
        self.inner = inner
    }

    /// 最近一次開環境時放進去的檔案路徑，依注入順序。
    var injectedPaths: [String] {
        recorded.withLock { $0.map(\.path) }
    }

    /// 記下注入檔再照常開。
    func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
        recorded.withLock { $0 = specification.injectedFiles }
        return try await inner.spawn(specification)
    }

    /// 原樣轉交。
    func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
        try await inner.exec(command, in: guest)
    }

    /// 原樣轉交。
    func ps() async throws -> [GuestSummary] {
        try await inner.ps()
    }

    /// 原樣轉交。
    func status(of guest: GuestIdentifier) async throws -> GuestSummary {
        try await inner.status(of: guest)
    }

    /// 原樣轉交。
    func destroy(_ guest: GuestIdentifier) async throws {
        try await inner.destroy(guest)
    }
}
