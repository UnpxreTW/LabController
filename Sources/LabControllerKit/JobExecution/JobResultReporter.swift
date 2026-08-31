//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把一份跑完的結果回報給站台：log 一段一段附上去，然後把終態寫進去。
///
/// 接的是 ``JobRunner`` 交出來的 ``JobRunReport``，用的是 ``JobRequestClient`` 的兩支端點。
/// 這一層不執行任何東西、也不領 job：**執行那一側不認識站台、協議那一側不認識執行**，中間
/// 這段翻譯獨立出來，兩邊才各自對得起自己的測試。
///
/// **終態比 log 重要**：一件 job 沒有終態就一直掛在站台上跑，直到站台自己判死，而那段時間
/// 它佔著併發額度、使用者看到的也是假的「執行中」。所以 log 送不完不會擋住終態——只有站台
/// 明說「這件 job 已經不在跑了」時才整個停手，因為那時再寫什麼都寫不進去。
///
/// **這一片只做跑完之後的回報**。執行途中就把 log 逐段推上去（真正的即時 trace）、安靜的
/// job 靠 keepalive 撈取消、以及領 job 那條 long-poll 迴圈，都不在這裡——它們各自需要一條
/// 與執行並行的線，而那條線該由誰持有是後續切片的事。這裡不先擺一個做不到的形狀。
public struct JobResultReporter: Sendable {

    /// 協議層 client。
    public let client: JobRequestClient

    /// 本機這一側的取捨。
    public let configuration: JobReportingConfiguration

    /// 等待一段時間的方式；測試注入假的，正式路徑真的睡。
    private let wait: @Sendable (TimeInterval) async throws -> Void

    /// 逐欄建立。
    ///
    /// - Parameters:
    ///   - client: 協議層 client。
    ///   - configuration: 本機設定。
    ///   - wait: 等待的方式；預設為真的睡指定秒數。
    public init(
        client: JobRequestClient = .init(),
        configuration: JobReportingConfiguration = .init(),
        wait: @escaping @Sendable (TimeInterval) async throws -> Void = Self.sleep
    ) {
        self.client = client
        self.configuration = configuration
        self.wait = wait
    }

    /// 把一份結果回報給站台：先送 log、再寫終態。
    ///
    /// - Parameters:
    ///   - report: 跑完的結果；其 trace 已經遮蔽過。
    ///   - target: 要回報到哪裡。
    /// - Returns: 站台收下的方式，以及 log 有沒有送完。
    /// - Throws: 連線層的錯（`GitLabAPIError` 或傳輸層自己的錯）。站台回的 403／416／202
    ///   都不算錯，它們是協議的一部分、由回傳值表達。
    public func report(_ report: JobRunReport, to target: JobReportTarget) async throws -> JobReportDelivery {
        let trace: TraceDelivery = try await sendTrace(report.trace, to: target)
        guard trace != .aborted else {
            return .init(acceptance: .aborted, traceIsComplete: false, updateAttempts: 0)
        }
        return try await writeTerminalState(of: report, to: target, traceIsComplete: trace == .sent)
    }

    /// 把整份 log 分段附到 job 上。
    ///
    /// - Parameters:
    ///   - trace: 已遮蔽的完整 log。
    ///   - target: 回寫座標。
    /// - Returns: 送完、送不完、或站台叫停。
    private func sendTrace(_ trace: String, to target: JobReportTarget) async throws -> TraceDelivery {
        let content: Data = .init(trace.utf8)
        guard !content.isEmpty else { return .sent }
        var offset: Int = 0
        var resyncs: Int = 0
        while offset < content.count {
            let end: Int = min(offset + configuration.traceChunkBytes, content.count)
            let acknowledgement: TraceAck = try await client.appendTrace(
                host: target.host,
                jobID: target.identifier,
                jobToken: target.token,
                chunk: content.subdata(in: offset ..< end),
                startOffset: offset
            )
            if acknowledgement.isAborted { return .aborted }
            if acknowledgement.needsResync {
                // 站台在 416 裡帶著它實際收到的位置，那是唯一的續傳依據；沒帶就無從得知
                // 該從哪裡接下去，硬猜只會把同一段重複寫進別人的 log 中間。
                guard
                    let resumption: Int = acknowledgement.nextOffset,
                    resumption <= content.count,
                    resyncs < configuration.maximumResyncAttempts
                else {
                    return .givenUp
                }
                resyncs += 1
                offset = resumption
                continue
            }
            // 站台說收到哪裡就從哪裡續，沒說就照本側送出的量推進。位置沒有往前走時停手：
            // 那代表這一段沒被收下，而照原位再送一次就是一個永遠不會結束的迴圈。
            let resumption: Int = acknowledgement.nextOffset ?? end
            guard
                resumption > offset,
                resumption <= content.count
            else { return .givenUp }
            offset = resumption
        }
        return .sent
    }

    /// 把終態寫進站台；站台只說「收下」時依它建議的間隔重送。
    ///
    /// - Parameters:
    ///   - report: 跑完的結果。
    ///   - target: 回寫座標。
    ///   - traceIsComplete: log 是否整份送達，原樣帶進回傳值。
    /// - Returns: 站台收下的方式。
    private func writeTerminalState(
        of report: JobRunReport,
        to target: JobReportTarget,
        traceIsComplete: Bool
    ) async throws -> JobReportDelivery {
        let state: JobState = report.outcome == .completed ? .success : .failed
        // 失敗分類只在失敗時送：協議上它決定站台端要不要重試，成功的 job 帶著一個分類過去
        // 不會被用到，但會出現在站台的紀錄裡，日後排查時是純粹的雜訊。
        let reason: JobFailureReason? = state == .failed ? report.failureReason : nil
        var attempts: Int = 0
        while true {
            let acknowledgement: JobUpdateAck = try await client.updateJob(
                host: target.host,
                jobID: target.identifier,
                jobToken: target.token,
                state: state,
                failureReason: reason,
                exitCode: report.exitCode.map(Int.init)
            )
            attempts += 1
            if acknowledgement.isAborted {
                return .init(acceptance: .aborted, traceIsComplete: traceIsComplete, updateAttempts: attempts)
            }
            if acknowledgement.isCompleted {
                return .init(acceptance: .written, traceIsComplete: traceIsComplete, updateAttempts: attempts)
            }
            guard attempts < configuration.maximumUpdateAttempts else {
                return .init(
                    acceptance: .notAcknowledged, traceIsComplete: traceIsComplete, updateAttempts: attempts
                )
            }
            try await wait(retryInterval(suggestedBy: acknowledgement.updateInterval))
        }
    }

    /// 決定兩次終態之間要等多久：站台的建議只在它是個能用的秒數時採信。
    ///
    /// 建議值原封來自回應標頭，`inf`、負數、或大到讓這條迴圈實質停住的值都是合法的字串輸入。
    /// 這種值不當成錯誤處理——它不影響這件 job 本身的結果，退回本機預設節奏即可，站台再說一次
    /// 就是了。上限也一併夾住：一個有限但過大的建議同樣會讓終態遲遲寫不進去。
    ///
    /// - Parameter suggestion: 站台建議的間隔（秒）；`nil` 代表沒建議。
    /// - Returns: 實際要等的秒數。
    private func retryInterval(suggestedBy suggestion: TimeInterval?) -> TimeInterval {
        guard
            let suggestion,
            suggestion.isFinite,
            suggestion >= 0
        else {
            return configuration.updateRetryInterval
        }
        return min(suggestion, configuration.maximumUpdateRetryInterval)
    }

    /// 正式路徑的等待：真的睡指定秒數。
    ///
    /// 負值、`inf`、`NaN`、以及換算成奈秒後放不進 `UInt64` 的值一律當成不睡：`UInt64` 對這些
    /// 值不是拋錯而是直接讓整個行程死掉，而這支被呼叫的位置正是「把終態寫回站台」的重送迴圈，
    /// 死在那裡等於終態永遠寫不進去。真正該把外部值夾在合理範圍內的是呼叫端，這裡只保證不死。
    ///
    /// - Parameter seconds: 要睡多久；不是有限非負秒數時當成不睡。
    @Sendable
    public static func sleep(_ seconds: TimeInterval) async throws {
        let nanoseconds: TimeInterval = max(0, seconds) * 1_000_000_000
        guard
            nanoseconds.isFinite,
            nanoseconds < TimeInterval(UInt64.max)
        else { return }
        try await Task.sleep(nanoseconds: .init(nanoseconds))
    }

    /// 送 log 的三種收法；只給本型別內部用。
    private enum TraceDelivery: Sendable, Equatable {

        /// 整份送到了。
        case sent

        /// 中途放棄，但這件 job 還在跑、終態照送。
        case givenUp

        /// 站台說這件 job 已經不在跑了，整個停手。
        case aborted
    }
}
