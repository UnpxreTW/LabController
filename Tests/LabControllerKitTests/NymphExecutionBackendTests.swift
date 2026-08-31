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

/// 把一行請求解成 JSON 物件；解不出即測試失敗。
private func object(_ line: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
}

/// 取出某個動詞的參數物件；動詞不對即測試失敗。
private func parameters(of line: Data, verb: String) throws -> [String: Any] {
    let envelope: [String: Any] = try #require(try object(line)[verb] as? [String: Any])
    return try #require(envelope["_0"] as? [String: Any])
}

/// 取送出去的第一行；一行都沒送即測試失敗。
private func firstLine(of transport: ScriptedNymphTransport) throws -> Data {
    try #require(transport.requests.withLock { $0.first })
}

/// 兩個 JSON 物件是否逐欄相同；鍵的順序不算差異。
private func same(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    NSDictionary(dictionary: lhs) == NSDictionary(dictionary: rhs)
}

/// 本檔共用的組態：macOS guest、其餘取預設。
private let configuration: NymphBackendConfiguration = .init(os: .mac)

/// 本檔共用的固定時刻，測試不取系統時鐘。
private let fixedNow: Date = .init(timeIntervalSince1970: 1_800_000_000)

/// 開一台 guest 之後、對面回來的那一行。
private let readySpawn: String = #"{"spawn":{"_0":{"id":"mfly-1","state":"ready","ip":"192.0.2.10"}}}"#

/// 一行成功且無輸出的 execute 回應。
private let emptyExecute: String = #"{"execute":{"_0":{"standardOutput":"","standardError":"","exit":0}}}"#

/// 一行成功的 destroy 回應。
private let destroyed: String = #"{"destroy":{"_0":{"id":"mfly-1","destroyed":true}}}"#

private final class NymphExecutionBackendTests {

    /// 開一台 guest 送出去的那一行，逐欄就是對面認得的形狀（含必填的 os 欄與不帶結尾換行）。
    @Test
    func `sends the spawn request in the shape the daemon accepts`() async throws {
        let transport: ScriptedNymphTransport = .init([readySpawn])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: .init(os: .mac))
        _ = try await backend.spawn(.init(image: .alias("golden-xcode")))
        let line: Data = try firstLine(of: transport)
        #expect(line.last != 0x0A)
        let expected: [String: Any] = try object(.init(#"""
            {"golden":"golden-xcode","os":"mac","cpus":4,"memoryGiB":4,"wait":true,"readinessTimeoutSeconds":180}
            """#.utf8))
        #expect(same(try parameters(of: line, verb: "spawn"), expected))
    }

    /// 組態裡的 guest 種類與規模原樣送出，不被本側改寫。
    @Test
    func `carries the configured guest kind and size`() async throws {
        let transport: ScriptedNymphTransport = .init([readySpawn])
        let backend: NymphExecutionBackend = .init(
            transport: transport,
            configuration: .init(os: .linux, cpus: 8, memoryGiB: 16, readinessTimeoutSeconds: 30)
        )
        _ = try await backend.spawn(.init(image: .alias("alpine")))
        let sent: [String: Any] = try parameters(of: try firstLine(of: transport), verb: "spawn")
        #expect(sent["os"] as? String == "linux")
        #expect(sent["cpus"] as? Int == 8)
        #expect(sent["memoryGiB"] as? Int == 16)
        #expect(sent["readinessTimeoutSeconds"] as? Int == 30)
    }

    /// 主機路徑當面拒絕：這條線上沒有那個欄位，連問都不問。
    @Test
    func `rejects a host path image without asking the daemon`() async throws {
        let transport: ScriptedNymphTransport = .init([readySpawn])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        await #expect(throws: ExecutionBackendError.self) {
            _ = try await backend.spawn(.init(image: .path("/tmp/golden.bundle")))
        }
        #expect(transport.requests.withLock { $0 }.isEmpty)
    }

    /// 等不到就緒時把那台清掉再拋——識別碼沒交出去，不清就沒有人清得到。
    @Test
    func `destroys the guest it could not bring up`() async throws {
        let booting: String = #"{"spawn":{"_0":{"id":"mfly-9","state":"booting","ip":null}}}"#
        let transport: ScriptedNymphTransport = .init([booting, destroyed])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        await #expect(throws: ExecutionBackendError.guestNotReady(.init("mfly-9"), state: .starting)) {
            _ = try await backend.spawn(.init(image: .alias("golden-xcode")))
        }
        let lines: [Data] = transport.requests.withLock { $0 }
        #expect(lines.count == 2)
        #expect(try parameters(of: lines[1], verb: "destroy")["id"] as? String == "mfly-9")
    }

    /// 注入檔在開機之後逐份寫進去：路徑與權限走位置參數、內容走 base64 的標準輸入。
    @Test
    func `writes injected files after the guest is up`() async throws {
        let transport: ScriptedNymphTransport = .init([readySpawn, emptyExecute])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        let file: InjectedFile = try .init(
            path: "/Users/runner/.config/token", contents: .init("s3cret".utf8), permissions: 0o640
        )
        _ = try await backend.spawn(.init(image: .alias("golden-xcode"), injectedFiles: [file]))
        let written: [String: Any] = try parameters(
            of: try #require(transport.requests.withLock { $0.last }), verb: "execute"
        )
        let command: [String] = try #require(written["command"] as? [String])
        #expect(command.first == "/bin/sh")
        #expect(command.dropLast(2).last == "sh")
        #expect(command.suffix(2) == ["/Users/runner/.config/token", "640"])
        #expect(written["standardInput"] as? String == Data("s3cret".utf8).base64EncodedString())
        #expect(written["id"] as? String == "mfly-1")
    }

    /// 注入寫不進去時把那台清掉，而且錯誤訊息只帶路徑與結束碼——這條路徑上流的是憑證。
    @Test
    func `destroys the guest when an injected file cannot be written`() async throws {
        let refused: String = #"""
            {"execute":{"_0":{"standardOutput":"","standardError":"permission denied: s3cret","exit":1}}}
            """#
        let transport: ScriptedNymphTransport = .init([readySpawn, refused, destroyed])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        let file: InjectedFile = try .init(path: "/etc/token", contents: .init("s3cret".utf8))
        await #expect(throws: ExecutionBackendError.requestRejected(detail: "注入檔寫不進去：/etc/token（結束碼 1）")) {
            _ = try await backend.spawn(.init(image: .alias("golden-xcode"), injectedFiles: [file]))
        }
        let lines: [Data] = transport.requests.withLock { $0 }
        #expect(lines.count == 3)
        #expect(try parameters(of: lines[2], verb: "destroy")["id"] as? String == "mfly-1")
    }

    /// 沒有注入檔就不多送任何一行。
    @Test
    func `sends nothing extra when there is no file to inject`() async throws {
        let transport: ScriptedNymphTransport = .init([readySpawn])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        let guest: GuestIdentifier = try await backend.spawn(.init(image: .alias("golden-xcode")))
        #expect(guest.rawValue == "mfly-1")
        #expect(transport.requests.withLock { $0 }.count == 1)
    }

    /// 命令的結束碼是資料：非零照樣回一份結果，不拋。
    @Test
    func `returns a non zero exit code as data`() async throws {
        let failed: String = #"""
            {"execute":{"_0":{"standardOutput":"3 problems","standardError":"lint","exit":2}}}
            """#
        let transport: ScriptedNymphTransport = .init([failed])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        let result: CommandResult = try await backend.exec(["swiftlint"], in: .init("mfly-1"))
        #expect(result.exitCode == 2)
        #expect(result.standardOutputText == "3 problems")
        #expect(result.standardErrorText == "lint")
        #expect(result.command == ["swiftlint"])
        let sent: [String: Any] = try parameters(of: try firstLine(of: transport), verb: "execute")
        #expect(sent["timeoutSeconds"] == nil)
        #expect(try #require(sent["environment"] as? [String: String]).isEmpty)
    }

    /// 查無此 guest 是本側協議裡的一則錯誤，不是一種結果。
    @Test
    func `maps the unknown identifier error onto the protocol`() async throws {
        let missing: String = #"{"toolError":{"_0":{"code":"no_such_id","message":"no such session id: mfly-7"}}}"#
        let transport: ScriptedNymphTransport = .init([missing])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        await #expect(throws: ExecutionBackendError.unknownGuest(.init("mfly-7"))) {
            _ = try await backend.exec(["true"], in: .init("mfly-7"))
        }
    }

    /// 還沒就緒的那則翻成「還在、但收不了命令」。
    @Test
    func `maps the not ready error onto a guest that cannot take commands`() async throws {
        let notReady: String = #"{"toolError":{"_0":{"code":"not_ready","message":"session is not ready"}}}"#
        let transport: ScriptedNymphTransport = .init([notReady])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        await #expect(throws: ExecutionBackendError.guestNotReady(.init("mfly-1"), state: .starting)) {
            _ = try await backend.exec(["true"], in: .init("mfly-1"))
        }
    }

    /// 對面拒絕的那幾則（基底不存在、額度滿了⋯）與「連不上」分開：重開一台有沒有用不一樣。
    @Test
    func `separates a refused request from an unusable backend`() async throws {
        let refused: String = #"{"toolError":{"_0":{"code":"golden_not_found","message":"golden alias not found: x"}}}"#
        let backend: NymphExecutionBackend = .init(
            transport: ScriptedNymphTransport([refused]), configuration: configuration
        )
        await #expect(throws: ExecutionBackendError.requestRejected(
            detail: "golden_not_found：golden alias not found: x"
        )) {
            _ = try await backend.spawn(.init(image: .alias("x")))
        }
    }

    /// 認不得的錯誤碼收成「這個後端當下用不了」，不猜成別的——猜錯會讓呼叫端把還在的那台劃掉。
    @Test
    func `treats an unrecognised error code as an unusable backend`() async throws {
        let unknown: String = #"{"toolError":{"_0":{"code":"quota_exhausted_v2","message":"later"}}}"#
        let backend: NymphExecutionBackend = .init(
            transport: ScriptedNymphTransport([unknown]), configuration: configuration
        )
        await #expect(throws: ExecutionBackendError.backendUnavailable(detail: "quota_exhausted_v2：later")) {
            _ = try await backend.exec(["true"], in: .init("mfly-1"))
        }
    }

    /// 連不上 daemon 時收成「這個後端當下用不了」，傳輸層的細節留在 detail 裡。
    @Test
    func `reports an unreachable daemon as an unusable backend`() async throws {
        let transport: ScriptedNymphTransport = .init([], failure: .connectionClosed)
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        await #expect(throws: ExecutionBackendError.self) {
            _ = try await backend.ps()
        }
    }

    /// 回應種類與送出的動詞對不上時大聲失敗，不當成空結果。
    @Test
    func `fails loudly when the response does not match the verb`() async throws {
        let transport: ScriptedNymphTransport = .init([destroyed])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        await #expect(throws: ExecutionBackendError.backendUnavailable(detail: "list 收到對不上的回應")) {
            _ = try await backend.ps()
        }
    }

    /// 列出時連停掉的一起要，並把對面的狀態與存活秒數翻成本側協議的樣子。
    @Test
    func `lists every guest including the stopped ones`() async throws {
        let sessions: String = #"""
            {"list":{"_0":{"sessions":[
            {"id":"mfly-1","state":"ready","ip":"192.0.2.10","golden":"golden-xcode","cpus":4,"memoryGiB":4,
            "uptimeSeconds":120},
            {"id":"mfly-2","state":"booting","ip":null,"golden":"golden-xcode","cpus":4,"memoryGiB":4,
            "uptimeSeconds":3},
            {"id":"mfly-3","state":"stopped","ip":null,"golden":"alpine","cpus":2,"memoryGiB":2,
            "uptimeSeconds":900}]}}}
            """#.replacingOccurrences(of: "\n", with: "")
        let transport: ScriptedNymphTransport = .init([sessions])
        let backend: NymphExecutionBackend = .init(
            transport: transport, configuration: configuration, now: { fixedNow }
        )
        let guests: [GuestSummary] = try await backend.ps()
        #expect(try parameters(of: try firstLine(of: transport), verb: "list")["all"] as? Bool == true)
        #expect(guests.map(\.state) == [.running, .starting, .stopped])
        #expect(guests.map(\.identifier.rawValue) == ["mfly-1", "mfly-2", "mfly-3"])
        #expect(guests.first?.image == .alias("golden-xcode"))
        #expect(guests.first?.startedAt == fixedNow.addingTimeInterval(-120))
        #expect(guests.last?.image == .alias("alpine"))
    }

    /// 查單一 guest 走同一套翻譯。
    @Test
    func `reads a single guest through the same translation`() async throws {
        let single: String = #"""
            {"status":{"_0":{"summary":{"id":"mfly-1","state":"ready","ip":"192.0.2.10","golden":"golden-xcode",
            "cpus":4,"memoryGiB":4,"uptimeSeconds":60},"stopReason":null}}}
            """#.replacingOccurrences(of: "\n", with: "")
        let backend: NymphExecutionBackend = .init(
            transport: ScriptedNymphTransport([single]), configuration: configuration, now: { fixedNow }
        )
        let summary: GuestSummary = try await backend.status(of: .init("mfly-1"))
        #expect(summary.state == .running)
        #expect(summary.image == .alias("golden-xcode"))
        #expect(summary.startedAt == fixedNow.addingTimeInterval(-60))
    }

    /// 查不到的那台在 status 上是錯誤。
    @Test
    func `reports an unknown guest when asked for its status`() async throws {
        let missing: String = #"{"toolError":{"_0":{"code":"no_such_id","message":"no such session id: mfly-4"}}}"#
        let backend: NymphExecutionBackend = .init(
            transport: ScriptedNymphTransport([missing]), configuration: configuration
        )
        await #expect(throws: ExecutionBackendError.unknownGuest(.init("mfly-4"))) {
            _ = try await backend.status(of: .init("mfly-4"))
        }
    }

    /// 清除硬停、不等它自己收尾。
    @Test
    func `destroys a guest without waiting for it to wind down`() async throws {
        let transport: ScriptedNymphTransport = .init([destroyed])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        try await backend.destroy(.init("mfly-1"))
        let sent: [String: Any] = try parameters(of: try firstLine(of: transport), verb: "destroy")
        #expect(sent["id"] as? String == "mfly-1")
        #expect(sent["force"] as? Bool == true)
    }

    /// 清第二次不算錯：對面說「沒有這個 id」，而那正是收拾路徑要的結果。
    @Test
    func `treats destroying a guest that is already gone as done`() async throws {
        let missing: String = #"{"toolError":{"_0":{"code":"no_such_id","message":"no such session id: mfly-1"}}}"#
        let backend: NymphExecutionBackend = .init(
            transport: ScriptedNymphTransport([missing]), configuration: configuration
        )
        try await backend.destroy(.init("mfly-1"))
    }

    /// 清除遇到別的錯照樣拋——只有「已經沒有了」那一則才吞。
    @Test
    func `still throws when destroying fails for another reason`() async throws {
        let broken: String = #"{"toolError":{"_0":{"code":"internal_error","message":"disk gone"}}}"#
        let backend: NymphExecutionBackend = .init(
            transport: ScriptedNymphTransport([broken]), configuration: configuration
        )
        await #expect(throws: ExecutionBackendError.backendUnavailable(detail: "internal_error：disk gone")) {
            try await backend.destroy(.init("mfly-1"))
        }
    }

    /// 協議自帶的收拾保證接得上：工作跑完之後那台被清掉。
    @Test
    func `cleans up the guest when the work is done`() async throws {
        let transport: ScriptedNymphTransport = .init([readySpawn, emptyExecute, destroyed])
        let backend: NymphExecutionBackend = .init(transport: transport, configuration: configuration)
        let code: Int32 = try await backend.withGuest(.init(image: .alias("golden-xcode"))) { guest in
            try await backend.exec(["true"], in: guest).exitCode
        }
        #expect(code == 0)
        let verbs: [String] = try transport.requests.withLock { $0 }.map { line in
            try #require(object(line).keys.first)
        }
        #expect(verbs == ["spawn", "execute", "destroy"])
    }
}
