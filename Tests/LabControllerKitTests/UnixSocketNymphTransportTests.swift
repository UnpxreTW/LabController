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

private final class UnixSocketNymphTransportTests {

    /// 一來一回：請求補上換行送出、回應把換行去掉才交回來。
    @Test
    func `sends one line and reads one line back`() async throws {
        let server: LoopbackSocketServer = try .init(response: #"{"destroy":{"_0":{"id":"mfly-1"}}}"#)
        defer { server.stop() }
        let transport: UnixSocketNymphTransport = .init(socketPath: server.path)
        let response: Data = try await transport.exchange(.init(#"{"list":{"_0":{"all":true}}}"#.utf8))
        #expect(String(decoding: response, as: UTF8.self) == #"{"destroy":{"_0":{"id":"mfly-1"}}}"#)
        let received: Data = try #require(server.received.withLock { $0 })
        #expect(String(decoding: received, as: UTF8.self) == "{\"list\":{\"_0\":{\"all\":true}}}\n")
    }

    /// 回應比一次讀取還長時照樣拼得回來——分幀看的是換行，不是單次讀到多少。
    @Test
    func `reassembles a response longer than one read`() async throws {
        let long: String = String(repeating: "a", count: 12_000)
        let server: LoopbackSocketServer = try .init(response: long)
        defer { server.stop() }
        let transport: UnixSocketNymphTransport = .init(socketPath: server.path)
        let response: Data = try await transport.exchange(.init("{}".utf8))
        #expect(String(decoding: response, as: UTF8.self) == long)
    }

    /// daemon 沒起來時是「連不上」，帶著路徑——那是排查的第一個問題。
    @Test
    func `reports a missing daemon as a connect failure`() async throws {
        let path: String = "/tmp/labcontroller-nymph-absent-\(UUID().uuidString.prefix(8)).sock"
        let transport: UnixSocketNymphTransport = .init(socketPath: path)
        await #expect(throws: NymphTransportError.self) {
            _ = try await transport.exchange(.init("{}".utf8))
        }
    }

    /// 路徑太長是另一回事：daemon 起得再成功也連不上，訊息要說得出來。
    @Test
    func `separates an over long socket path from a missing daemon`() async throws {
        let path: String = "/tmp/" + String(repeating: "p", count: 120) + ".sock"
        let transport: UnixSocketNymphTransport = .init(socketPath: path)
        await #expect(throws: NymphTransportError.pathTooLong(path: path)) {
            _ = try await transport.exchange(.init("{}".utf8))
        }
    }

    /// 預設路徑跟著環境變數走；兩邊算出不同的地方時，症狀只會是「明明在跑卻連不上」。
    @Test
    func `resolves the default socket path from the environment`() async throws {
        #expect(
            UnixSocketNymphTransport.defaultSocketPath(environment: ["MAYFLY_STATE_DIR": "/tmp/mayfly-state"])
                == "/tmp/mayfly-state/nymph.sock"
        )
        let fallback: String = UnixSocketNymphTransport.defaultSocketPath(environment: [:])
        #expect(fallback.hasSuffix("/.mayfly/nymph.sock"))
    }
}
