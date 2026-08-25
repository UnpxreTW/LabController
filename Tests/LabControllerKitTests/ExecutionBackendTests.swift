//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Testing

private final class ExecutionBackendTests {

    /// 測試共用的環境規格。
    private let specification: GuestSpecification = .init(image: .alias("ci-linux"))

    // MARK: - 注入檔

    /// 相對路徑不收：相對於誰，本側答不出來。
    @Test
    func `rejects an injected file at a relative path`() {
        #expect(throws: InjectedFileError.pathNotAbsolute("etc/token")) {
            try InjectedFile(path: "etc/token", contents: .init())
        }
    }

    /// 含 `..` 段的路徑不收：字面與實際落點不同。
    @Test
    func `rejects an injected file path with a relative component`() {
        #expect(throws: InjectedFileError.pathHasRelativeComponent("/run/secrets/../token")) {
            try InjectedFile(path: "/run/secrets/../token", contents: .init())
        }
    }

    /// 權限超出八進位三碼即拋。
    @Test
    func `rejects injected file permissions beyond three octal digits`() {
        #expect(throws: InjectedFileError.permissionsOutOfRange(0o1000)) {
            try InjectedFile(path: "/run/token", contents: .init(), permissions: 0o1000)
        }
    }

    /// 沒指定權限時關到最緊。
    @Test
    func `defaults injected file permissions to owner only`() throws {
        let file: InjectedFile = try .init(path: "/run/token", contents: .init())
        #expect(file.permissions == 0o600)
    }

    /// 注入檔在環境開起來時就位。
    @Test
    func `places injected files in the guest at spawn`() async throws {
        let file: InjectedFile = try .init(path: "/run/token", contents: .init("glrt-x".utf8))
        let backend: InMemoryExecutionBackend = .init()
        let guest: GuestIdentifier = try await backend.spawn(.init(image: .alias("ci-linux"), injectedFiles: [file]))
        #expect(backend.injectedFiles(in: guest) == [file])
    }

    // MARK: - 命令結果

    /// 非零結束碼是結果、不是拋出。
    @Test
    func `returns a non-zero exit code as data`() async throws {
        let failing: CommandResult = .init(
            command: ["swiftlint"],
            exitCode: 2,
            standardError: .init("3 violations".utf8)
        )
        let backend: InMemoryExecutionBackend = .init(script: .init(results: ["swiftlint": failing]))
        let guest: GuestIdentifier = try await backend.spawn(specification)
        let result: CommandResult = try await backend.exec(["swiftlint"], in: guest)
        #expect(result.exitCode == 2)
        #expect(result.isSuccess == false)
        #expect(result.standardErrorText == "3 violations")
    }

    /// 要求必須成功時，零結束碼原樣回。
    @Test
    func `passes a zero exit code through when success is required`() throws {
        let result: CommandResult = .init(command: ["true"], exitCode: 0)
        #expect(try result.requireSuccess() == result)
    }

    /// 要求必須成功時，非零連同整份結果一起拋。
    @Test
    func `throws the whole result when a required command fails`() {
        let result: CommandResult = .init(command: ["false"], exitCode: 1, standardError: .init("nope".utf8))
        #expect(throws: CommandFailure(result: result)) {
            try result.requireSuccess()
        }
    }

    /// 不是 UTF-8 的輸出不會讓原始位元組跟著壞掉。
    @Test
    func `keeps raw bytes intact when output is not valid UTF-8`() {
        let bytes: Data = .init([0xFF, 0xFE, 0x41])
        let result: CommandResult = .init(command: ["cat"], exitCode: 0, standardOutput: bytes)
        #expect(result.standardOutput == bytes)
        #expect(result.standardOutputText.contains("A"))
    }

    // MARK: - 環境生命週期

    /// 開起來的環境是可以收命令的狀態，且列得到。
    @Test
    func `lists a spawned guest as running`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let guest: GuestIdentifier = try await backend.spawn(specification)
        let summary: GuestSummary = try await backend.status(of: guest)
        #expect(summary.state == .running)
        #expect(summary.image == .alias("ci-linux"))
        #expect(try await backend.ps() == [summary])
    }

    /// 焚毀之後查不到，而不是查到一個「已焚毀」的狀態。
    @Test
    func `stops reporting a guest once it is destroyed`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let guest: GuestIdentifier = try await backend.spawn(specification)
        try await backend.destroy(guest)
        #expect(try await backend.ps().isEmpty)
        await #expect(throws: ExecutionBackendError.unknownGuest(guest)) {
            try await backend.status(of: guest)
        }
    }

    /// 對不存在的環境下命令＝根本沒跑成，走錯誤面。
    @Test
    func `fails a command aimed at a guest that is gone`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let guest: GuestIdentifier = .init("guest-does-not-exist")
        await #expect(throws: ExecutionBackendError.unknownGuest(guest)) {
            try await backend.exec(["true"], in: guest)
        }
    }

    // MARK: - 收拾保證

    /// 工作正常結束時環境被焚毀，回傳值原樣帶出。
    @Test
    func `destroys the guest after the work finishes`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let value: Int = try await backend.withGuest(specification) { guest in
            _ = try await backend.exec(["echo"], in: guest)
            return 7
        }
        #expect(value == 7)
        #expect(backend.destroyCount == 1)
        #expect(try await backend.ps().isEmpty)
    }

    /// 工作拋出時環境照樣被焚毀，拋出去的仍是工作自己的錯。
    @Test
    func `destroys the guest and rethrows when the work throws`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        await #expect(throws: ExecutionTestMarkerError()) {
            try await backend.withGuest(specification) { _ in
                throw ExecutionTestMarkerError()
            }
        }
        #expect(backend.destroyCount == 1)
        #expect(try await backend.ps().isEmpty)
    }

    /// 工作拋出時，焚毀若也失敗，拋出去的仍是工作那一個。
    @Test
    func `keeps the work error when cleanup also fails`() async throws {
        let backend: InMemoryExecutionBackend = .init(script: .init(destroyError: .backendUnavailable(detail: "gone")))
        await #expect(throws: ExecutionTestMarkerError()) {
            try await backend.withGuest(specification) { _ in
                throw ExecutionTestMarkerError()
            }
        }
    }

    /// 工作正常結束、焚毀失敗時，焚毀的錯不被吞掉。
    @Test
    func `surfaces a cleanup failure when the work succeeds`() async {
        let backend: InMemoryExecutionBackend = .init(script: .init(destroyError: .backendUnavailable(detail: "gone")))
        await #expect(throws: ExecutionBackendError.backendUnavailable(detail: "gone")) {
            try await backend.withGuest(self.specification) { _ in }
        }
    }
}
