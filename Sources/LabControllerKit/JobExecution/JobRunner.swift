//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把一份消化過的 payload 在一個一次性執行環境裡跑完，回報怎麼收的。
///
/// 接的是 ``JobAdmission`` 收下的 ``JobPlan``，用的是 ``ExecutionBackend`` 那五個動作，
/// 中間隔著 ``JobWorkspace`` 鋪出來的檔案樹。**這一層不碰站台**：trace 與終態怎麼回寫是
/// ``JobRequestClient`` 那一側的事，兩者分開才能各自對著假的另一半測。
///
/// **時間上限只在步驟與步驟之間看**：協議沒有取消，硬把一個跑飛的命令收掉的唯一手段是焚毀
/// 整個環境，而那需要另一條與執行並行的看門線。所以這裡的保證是「不會再『開始』新的步驟」，
/// 不是「一定在期限內結束」；真正的看門與容量治理是後續切片的事，不在這裡假裝已經有了。
/// 連帶的一個缺口一併寫明：**逾時之後連 `when: always` 的收拾步驟也不跑**——那類步驟要有
/// 意義就得自帶一份不受本次預算約束的時間，而「另給一份預算」正是看門線那一片要一起決定的
/// 事。在它到位之前，這裡寧可誠實地不跑，也不要給一個沒有盡頭的收拾階段。
public struct JobRunner: Sendable {

    /// 用哪個後端開環境。
    public let backend: any ExecutionBackend

    /// 本機這一側的設定。
    public let configuration: JobRunnerConfiguration

    /// 取當下時刻；測試靠它推時鐘，正式路徑取系統時間。
    private let now: @Sendable () -> Date

    /// 逐欄建立。
    ///
    /// - Parameters:
    ///   - backend: 執行後端。
    ///   - configuration: 本機設定。
    ///   - now: 取當下時刻的方式。
    public init(
        backend: any ExecutionBackend,
        configuration: JobRunnerConfiguration = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.backend = backend
        self.configuration = configuration
        self.now = now
    }

    /// 開一個環境、取碼、逐步驟跑完，然後把環境焚毀。
    ///
    /// - Parameters:
    ///   - plan: 消化過的 payload。
    ///   - image: 要從哪一份基底開環境。
    /// - Returns: 這次的結果；跑不成也是一份結果、不拋。
    public func run(_ plan: JobPlan, on image: GuestImage) async -> JobRunReport {
        let trace: TraceRecorder = .init(masker: plan.masker)
        for warning in plan.warnings {
            trace.write(warning.traceMessage)
        }
        let workspace: JobWorkspace
        do {
            workspace = try .init(plan: plan, root: configuration.workspaceRoot)
        } catch {
            // 錯誤訊息內插的是變數名而不是值，但仍走遮蔽通道——「這條路徑上應該沒有秘密」
            // 是一種會過期的推論，而過期的那一次就是秘密上站台的那一次。
            trace.write("執行環境的檔案準備不起來：\(error)")
            return .init(outcome: .systemFailed, failureReason: .runnerSystemFailure, trace: trace.finish(),
                         warnings: plan.warnings)
        }
        let deadline: Date = now().addingTimeInterval(.init(plan.timeoutSeconds))
        let specification: GuestSpecification = .init(image: image, injectedFiles: workspace.injectedFiles)
        // 跑完的結果先放在這裡，才不會被收拾階段的錯蓋掉：`withGuest` 在工作正常結束、
        // 焚毀卻失敗時拋的是焚毀那個錯，而那時 job 其實已經跑完了。把一件已經做完（甚至
        // 已經推了東西出去）的 job 回報成「環境錯、可重試」，站台端會整件重跑一次。
        let finished: FinishedRun = .init()
        do {
            return try await backend.withGuest(specification) { guest in
                let report: JobRunReport = try await execute(plan, in: workspace, on: guest, before: deadline,
                                                             recording: trace)
                finished.report = report
                return report
            }
        } catch {
            guard let report: JobRunReport = finished.report else {
                trace.write("執行環境沒能把事情做成：\(error)")
                return .init(outcome: .systemFailed, failureReason: .runnerSystemFailure, trace: trace.finish(),
                             warnings: plan.warnings)
            }
            // 收拾失敗不改寫結果，但也不吞掉：留下來的環境仍在 `ps()` 上看得到，回收孤兒
            // 本來就是後端那一側的事（見 `ExecutionBackend.withGuest` 的說明）。
            trace.write("環境沒能焚毀：\(error)")
            return .init(outcome: report.outcome, failureReason: report.failureReason, exitCode: report.exitCode,
                         trace: trace.finish(), warnings: report.warnings)
        }
    }

    /// 在已開好的環境裡取碼並逐步驟跑。
    ///
    /// - Throws: ``ExecutionBackendError``——那類是「根本沒跑成」，由 ``run(_:on:)`` 收成
    ///   ``JobOutcome/systemFailed``；命令自己的非零結束碼不在此列，它是結果。
    private func execute(
        _ plan: JobPlan,
        in workspace: JobWorkspace,
        on guest: GuestIdentifier,
        before deadline: Date,
        recording trace: TraceRecorder
    ) async throws -> JobRunReport {
        if let checkout: String = workspace.checkoutScriptPath {
            trace.write("$ 取得程式碼")
            let result: CommandResult = try await backend.exec(command(running: checkout), in: guest)
            trace.write(output(of: result))
            guard result.isSuccess else {
                // 取不到碼算環境錯、不算 job 錯：CI 檔沒有任何一行跑過，紅在這裡不是它的責任，
                // 而站台端對環境錯會重試——下一次多半就取得到了。
                trace.write("取得程式碼失敗（結束碼 \(result.exitCode)），本次一個步驟都不跑。")
                return report(plan, outcome: .systemFailed, reason: .runnerSystemFailure,
                              exitCode: result.exitCode, trace: trace)
            }
        }
        var hasFailed: Bool = false
        var firstFailureExitCode: Int32?
        for (index, step) in plan.steps.enumerated() {
            guard step.runCondition.shouldRun(afterFailure: hasFailed) else {
                trace.write("略過步驟 \(step.name)：它的執行條件是 \(step.runCondition.rawValue)。")
                continue
            }
            guard now() < deadline else {
                trace.write("已達本次 job 的時間上限（\(plan.timeoutSeconds) 秒），其餘步驟不再開始。")
                // 已經有步驟失敗過的話，死因是那個失敗、不是逾時：把終態換成逾時等於用收尾的
                // 樣子蓋掉真正的原因，而站台端對兩者的重試政策並不相同。
                guard !hasFailed else {
                    return report(plan, outcome: .jobFailed, reason: .scriptFailure,
                                  exitCode: firstFailureExitCode, trace: trace)
                }
                return report(plan, outcome: .timeout, reason: .jobExecutionTimeout, exitCode: nil, trace: trace)
            }
            trace.write("$ \(step.name)")
            let result: CommandResult = try await backend.exec(command(running: workspace.stepScriptPaths[index]),
                                                               in: guest)
            trace.write(output(of: result))
            guard !result.isSuccess else { continue }
            guard !step.allowFailure else {
                trace.write("步驟 \(step.name) 以結束碼 \(result.exitCode) 結束；該步驟允許失敗，繼續往下跑。")
                continue
            }
            trace.write("步驟 \(step.name) 以結束碼 \(result.exitCode) 失敗。")
            hasFailed = true
            if firstFailureExitCode == nil {
                firstFailureExitCode = result.exitCode
            }
        }
        guard hasFailed else { return report(plan, outcome: .completed, exitCode: 0, trace: trace) }
        return report(plan, outcome: .jobFailed, reason: .scriptFailure, exitCode: firstFailureExitCode, trace: trace)
    }

    /// 收尾成一份結果；trace 在此刻收攏，之後不再寫入。
    private func report(
        _ plan: JobPlan,
        outcome: JobOutcome,
        reason: JobFailureReason? = nil,
        exitCode: Int32?,
        trace: TraceRecorder
    ) -> JobRunReport {
        .init(outcome: outcome, failureReason: reason, exitCode: exitCode, trace: trace.finish(),
              warnings: plan.warnings)
    }

    /// 跑一份腳本的完整命令。
    private func command(running script: String) -> [String] {
        configuration.shell + [script]
    }

    /// 一道命令的兩道輸出，先標準輸出、後標準錯誤。
    ///
    /// **兩者真正的交錯順序在協議上拿不到**（``CommandResult`` 各收各的），所以這裡是重排過的
    /// 呈現、不是實況重播。要看實況得等能逐段收輸出的後端通道，那時 trace 也才有得串流。
    private func output(of result: CommandResult) -> String {
        [result.standardOutputText, result.standardErrorText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 一份逐段遮蔽、逐段累積的 trace 抄本。
    ///
    /// 做成參考型別是因為它要跨越 ``ExecutionBackend/withGuest(_:do:)`` 的閉包邊界——工作在
    /// 裡面寫、收拾之後在外面還要再寫一行，兩邊必須是同一份，否則環境開不起來時那一段說明
    /// 會連同抄本一起消失。
    private final class TraceRecorder {

        /// 跨段遮蔽的緩衝器。
        private var stream: MaskedTraceStream

        /// 已放行的內容。
        private var released: String = ""

        /// 以遮蔽規則建立。
        init(masker: TraceMasker) {
            self.stream = .init(masker: masker)
        }

        /// 寫一行；空字串不寫，免得 trace 裡多出成排的空行。
        func write(_ line: String) {
            guard !line.isEmpty else { return }
            released += stream.append(line + "\n")
        }

        /// 收攏並取回全文；緩衝區裡押著的尾巴在此放行。
        ///
        /// 放行的內容併回已放行的那份，所以收攏之後還能再寫、再收一次——收拾階段還要補一行的
        /// 那條路徑走的就是這個。
        func finish() -> String {
            released += stream.flush()
            return released
        }
    }

    /// 裝一份「工作已經跑完」的結果的盒子。
    ///
    /// 存在理由與 ``TraceRecorder`` 同：``ExecutionBackend/withGuest(_:do:)`` 在工作正常結束、
    /// 焚毀卻失敗時拋的是焚毀那個錯，於是閉包的回傳值到不了外面。沒有這個盒子，一件跑完的 job
    /// 會被收拾階段的錯蓋成系統層失敗。
    private final class FinishedRun {

        /// 工作跑完的結果；工作自己拋出時為 nil。
        var report: JobRunReport?
    }
}
