//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// 走 Unix domain socket 的 ``NymphTransport``：連上、寫一行、讀一行、關掉。
///
/// **每次呼叫都重開一條連線**：對面就是這樣收的，而且這條線的請求量以「開一台機器」為單位——
/// 重用連線省下的握手時間，換來的是要自己判斷一條放了很久的連線還活著沒有，而判斷錯的那一次
/// 是把一則請求寫進一個已經死掉的 socket、然後等一個永遠不會來的回應。
///
/// **阻塞的 syscall 丟到自己的佇列上跑**：`connect`／`read`／`write` 會把呼叫它的執行緒停住，
/// 而 Swift 並行的執行緒池只有幾條——直接在 async 函式裡呼叫，等於一次 spawn 就佔住其中一條
/// 十幾秒，整個行程的其他工作跟著停。
public struct UnixSocketNymphTransport: NymphTransport {

    // MARK: Public

    /// socket 檔的路徑。
    public let socketPath: String

    /// 以 socket 路徑建立。
    ///
    /// - Parameter socketPath: nymph 的 socket 檔；預設走 ``defaultSocketPath(environment:)``。
    public init(socketPath: String = UnixSocketNymphTransport.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    /// 依環境解出預設 socket 路徑：`MAYFLY_STATE_DIR` 指定的目錄，否則家目錄下的 `.mayfly`。
    ///
    /// **這份規則抄自對面、且必須跟著它**：兩邊算出不同的路徑時不會有任何錯誤訊息說「你們算的
    /// 不是同一個地方」，只會表現成「daemon 明明在跑卻連不上」。路徑短也是規則的一部分——
    /// `sun_path` 只有一百出頭個位元組。
    ///
    /// - Parameter environment: 讀環境變數用；預設取本行程的。
    /// - Returns: socket 檔的絕對路徑。
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let stateDirectory: URL
        if let override: String = environment[stateDirectoryEnvironmentKey], !override.isEmpty {
            stateDirectory = .init(fileURLWithPath: override, isDirectory: true)
        } else {
            stateDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(component: ".mayfly")
        }
        return stateDirectory.appending(component: "nymph.sock").path
    }

    /// 送出一行請求、讀回一行回應。
    ///
    /// - Parameter requestLine: 請求 JSON，不含換行。
    /// - Returns: 回應 JSON，不含換行。
    /// - Throws: ``NymphTransportError``。
    public func exchange(_ requestLine: Data) async throws -> Data {
        let path: String = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try Self.roundTrip(requestLine, socketPath: path) })
            }
        }
    }

    // MARK: Private

    /// 覆寫 state 目錄的環境變數名，與對面同名。
    private static let stateDirectoryEnvironmentKey: String = "MAYFLY_STATE_DIR"

    /// 一次讀取的緩衝大小。
    private static let readChunkSize: Int = 4096

    /// 換行的位元組值，即協議的分幀符。
    private static let newline: UInt8 = 0x0A

    /// 跑阻塞 syscall 的佇列；並行、每個請求各自佔一條執行緒。
    private static let queue: DispatchQueue = .init(
        label: "me.unpxre.labcontroller.nymph-transport", attributes: .concurrent
    )

    /// 連線、寫請求、讀回應、關閉；全程阻塞，只在 ``queue`` 上跑。
    private static func roundTrip(_ requestLine: Data, socketPath: String) throws -> Data {
        let descriptor: Int32 = try connect(to: socketPath)
        defer { close(descriptor) }
        var payload: Data = requestLine
        payload.append(newline)
        try writeAll(payload, to: descriptor)
        return try readLine(from: descriptor)
    }

    /// 開一個 `AF_UNIX` socket 並連上指定路徑。
    private static func connect(to socketPath: String) throws -> Int32 {
        var address: sockaddr_un = .init()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes: [UInt8] = .init(socketPath.utf8)
        // 結尾的 NUL 也要放得下，故是嚴格小於。
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw NymphTransportError.pathTooLong(path: socketPath)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let descriptor: Int32 = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NymphTransportError.connectFailed(path: socketPath, detail: errnoDetail())
        }
        // 對面先關掉連線時，寫入預設會以 SIGPIPE 殺掉整個行程；改成讓 `write` 回 -1，錯誤才
        // 回得到呼叫端。
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let outcome: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard outcome == 0 else {
            let detail: String = errnoDetail()
            close(descriptor)
            throw NymphTransportError.connectFailed(path: socketPath, detail: detail)
        }
        return descriptor
    }

    /// 把整份資料寫出去；一次寫不完就接著寫。
    private static func writeAll(_ payload: Data, to descriptor: Int32) throws {
        var remaining: Data = payload
        while !remaining.isEmpty {
            let written: Int = remaining.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { throw NymphTransportError.writeFailed(detail: errnoDetail()) }
            remaining = remaining.dropFirst(written)
        }
    }

    /// 讀到第一個換行為止；回傳不含換行的那一段。
    private static func readLine(from descriptor: Int32) throws -> Data {
        var accumulated: Data = .init()
        var buffer: [UInt8] = .init(repeating: 0, count: readChunkSize)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { destination in
                Darwin.read(descriptor, destination.baseAddress, destination.count)
            }
            guard count > 0 else { throw NymphTransportError.connectionClosed }
            let chunk: ArraySlice<UInt8> = buffer[0 ..< count]
            guard let index: Int = chunk.firstIndex(of: newline) else {
                accumulated.append(contentsOf: chunk)
                continue
            }
            accumulated.append(contentsOf: buffer[0 ..< index])
            return accumulated
        }
    }

    /// 取當下 `errno` 的人讀說明，供錯誤 `detail` 用。
    private static func errnoDetail() -> String {
        .init(cString: strerror(errno))
    }
}
