//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Synchronization

/// 在本行程裡起一個 Unix domain socket，收一條連線、讀一行、回一行、關掉。
///
/// **傳輸層要對著真的 socket 測**：這一段的內容全是 POSIX 呼叫與分幀，換成假的介面等於把要驗
/// 的東西整個拿掉——寫了幾個位元組、換行有沒有補上、對方關線時會不會卡住，都只有真的接上另一端
/// 才看得到。
internal final class LoopbackSocketServer: Sendable {

    /// socket 檔的路徑。
    ///
    /// 落在 `/tmp` 而不是測試專用暫存目錄：`sun_path` 只有一百出頭個位元組，而暫存目錄的路徑
    /// 本身就可能吃掉大半。
    internal let path: String

    /// 收到的那一行請求，含結尾換行；還沒收到時為 nil。
    internal let received: Mutex<Data?> = .init(nil)

    /// 以要回覆的內容建立並開始聽。
    ///
    /// - Parameter response: 收到請求後回的那一行，不含換行；由本型別補上。
    /// - Throws: 綁不起來時拋 `POSIXError`。
    internal init(response: String) throws {
        path = "/tmp/labcontroller-nymph-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        let listener: Int32 = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address: sockaddr_un = .init()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes: [UInt8] = .init(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let bound: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(listener, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard
            bound == 0,
            listen(listener, 1) == 0
        else {
            let code: Int32 = errno
            close(listener)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        self.listener = listener
        serve(response: response)
    }

    /// 關掉 socket 並清掉 socket 檔。
    internal func stop() {
        close(listener)
        unlink(path)
    }

    /// listen 用的檔案描述子。
    private let listener: Int32

    /// 在另一條執行緒上等一條連線、讀一行、回一行。
    ///
    /// 用 `Thread` 而不是 `Task`：`accept` 與 `read` 會把執行緒停住，而 Swift 並行的執行緒池
    /// 只有幾條——停住其中一條，同一個測試裡的另一半就跑不動了。
    private func serve(response: String) {
        let thread: Thread = .init { [self] in
            let connection: Int32 = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            var line: Data = .init()
            var buffer: [UInt8] = .init(repeating: 0, count: 1024)
            while !line.contains(0x0A) {
                let count: Int = buffer.withUnsafeMutableBytes { destination in
                    Darwin.read(connection, destination.baseAddress, destination.count)
                }
                guard count > 0 else { break }
                line.append(contentsOf: buffer[0 ..< count])
            }
            received.withLock { $0 = line }
            var payload: Data = .init(response.utf8)
            payload.append(0x0A)
            payload.withUnsafeBytes { source in
                _ = Darwin.write(connection, source.baseAddress, source.count)
            }
            close(connection)
        }
        thread.start()
    }
}
