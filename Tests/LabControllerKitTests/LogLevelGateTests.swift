//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import LabControllerKit
import Logging
import Synchronization
import Testing

private final class LogLevelGateTests {

    /// 門檻在 `Logger` 建出來之後才改，一樣管得到後面送的每一行。
    ///
    /// 這是整層 gate 存在的理由：後端得在解析引數之前裝好，門檻要等解析完才知道。
    @Test
    func `raising the threshold after the logger exists filters the lower lines`() {
        let threshold: LogLevelThreshold = .init()
        let lines: Mutex<[String]> = .init([])
        let logger: Logger = .init(label: "test") { _ in
            LogLevelGate(
                downstream: CapturingLogHandler(record: { _, line in lines.withLock { $0.append(line) } }),
                threshold: threshold
            )
        }
        logger.info("first")
        threshold.set(.error)
        logger.info("second")
        logger.error("third")
        #expect(lines.withLock { $0 } == ["first", "third"])
    }

    /// 門檻預設 `info`：更低的等級不落。
    @Test
    func `the default threshold drops anything below info`() {
        let threshold: LogLevelThreshold = .init()
        let lines: Mutex<[String]> = .init([])
        let logger: Logger = .init(label: "test") { _ in
            LogLevelGate(
                downstream: CapturingLogHandler(record: { _, line in lines.withLock { $0.append(line) } }),
                threshold: threshold
            )
        }
        logger.debug("dropped")
        logger.notice("kept")
        #expect(lines.withLock { $0 } == ["kept"])
    }

    /// 由後端那一側設門檻，寫的是同一份。
    @Test
    func `setting the level through the handler writes the shared threshold`() {
        let threshold: LogLevelThreshold = .init()
        var gate: LogLevelGate = .init(downstream: CapturingLogHandler(record: { _, _ in }), threshold: threshold)
        gate.logLevel = .warning
        #expect(threshold.level == .warning)
        #expect(gate.logLevel == .warning)
    }

    /// 隨紀錄帶出的欄位原樣轉給下游。
    @Test
    func `metadata is forwarded to the downstream handler`() {
        var gate: LogLevelGate = .init(downstream: CapturingLogHandler(record: { _, _ in }))
        gate[metadataKey: "job"] = "42"
        #expect(gate.metadata["job"] == "42")
        #expect(gate[metadataKey: "job"] == "42")
    }
}
