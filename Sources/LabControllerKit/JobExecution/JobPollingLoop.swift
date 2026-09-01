//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把「領一件、收不收、跑、回寫」串成一圈的迴圈。
///
/// 這一層自己不決定任何事：收不收由 ``JobAdmission`` 判、怎麼跑由 ``JobRunner`` 做、回寫的
/// 重試與續傳由 ``JobResultReporter`` 管。它只負責把四者接起來，並且守住兩件接起來才會出現
/// 的事——**游標要一路帶著走**（連沒領到的那些輪次也要，否則站台端不 hold、long-poll 等於
/// 沒開），以及**兩把 token 各走各的**：領件用 runner 認證 token，回寫用站台隨該件 job 發的
/// 專屬 token，混用即為權限錯置。
///
/// 一次只經手一件 job：多開幾格是容量治理那一片的事，而那一片要先有逾時與殘骸回收才成立。
public struct JobPollingLoop: Sendable {

    /// 這圈迴圈要往哪個站台領件、用哪把 token、開哪一份基底。
    ///
    /// ⚠️ 本型別持有 runner 認證 token，故**不合成 `Equatable`／`CustomStringConvertible`**：
    /// 兩者都會讓這把 token 有機會被印進錯誤訊息或測試輸出。
    public struct Configuration: Sendable {

        /// GitLab 站台基底網址。
        public let host: String

        /// runner 認證 token；只用於領件，絕不進回寫路徑，也絕不寫進 log。
        public let runnerToken: String

        /// 每件 job 要從哪一份基底開執行環境。
        public let image: GuestImage

        /// 本機執行面的設定（工作目錄根、shell）。
        public let runner: JobRunnerConfiguration

        /// 領件這一步失敗後，隔多久再敲下一次。
        ///
        /// 失敗多半是站台或網路暫時不在，退開一段再試即可；不退直接重敲會在站台掛掉的期間
        /// 打出一串緊迴圈，把本來只是慢的情況變成兩邊都更忙。
        public let retryInterval: TimeInterval

        /// 逐欄建立。
        ///
        /// - Parameters:
        ///   - host: 站台基底網址。
        ///   - runnerToken: runner 認證 token。
        ///   - image: 開執行環境用的基底。
        ///   - runner: 本機執行面設定；預設值見 ``JobRunnerConfiguration``。
        ///   - retryInterval: 領件失敗後的退避秒數；預設 30。
        public init(
            host: String,
            runnerToken: String,
            image: GuestImage,
            runner: JobRunnerConfiguration = .init(),
            retryInterval: TimeInterval = 30
        ) {
            self.host = host
            self.runnerToken = runnerToken
            self.image = image
            self.runner = runner
            self.retryInterval = retryInterval
        }
    }

    /// 協議層 client；領件與回寫共用同一個。
    public let client: JobRequestClient

    /// 用哪個後端開執行環境。
    public let backend: any ExecutionBackend

    /// 回寫用的回報器。
    public let reporter: JobResultReporter

    /// 這圈迴圈的設定。
    public let configuration: Configuration

    /// 退避時等待的方式；測試注入不真的睡的版本。
    private let wait: @Sendable (TimeInterval) async -> Void

    /// 逐欄建立。
    ///
    /// - Parameters:
    ///   - client: 協議層 client。
    ///   - backend: 執行後端。
    ///   - reporter: 回寫用的回報器。
    ///   - configuration: 迴圈設定。
    ///   - wait: 退避時等待的方式；預設真的睡指定秒數。
    public init(
        client: JobRequestClient = .init(),
        backend: any ExecutionBackend,
        reporter: JobResultReporter = .init(),
        configuration: Configuration,
        wait: @escaping @Sendable (TimeInterval) async -> Void = JobPollingLoop.sleep
    ) {
        self.client = client
        self.backend = backend
        self.reporter = reporter
        self.configuration = configuration
        self.wait = wait
    }

    /// 領一件：領到就跑完並回寫，沒領到就只把游標帶回來。
    ///
    /// - Parameter cursor: 上一輪帶回來的游標；第一輪給 nil。
    /// - Returns: 這一輪的處置與下一輪要帶的游標。
    /// - Throws: 領件或回寫的連線層錯誤。**跑 job 本身不會拋**——跑不成也是一份結果，
    ///   照樣回寫給站台（見 ``JobRunner/run(_:on:)``）。
    public func poll(cursor: String?) async throws -> JobCycle {
        let result: JobRequestResult = try await client.requestJob(
            host: configuration.host,
            token: configuration.runnerToken,
            lastUpdate: cursor
        )
        guard case let .assigned(job) = result.outcome else {
            return .init(disposition: .idle, cursor: result.lastUpdate)
        }
        // 回寫一律用站台隨這件 job 發的專屬 token；runner 認證 token 到上面那一行為止。
        let target: JobReportTarget = .init(host: configuration.host, identifier: job.id, token: job.token)
        switch JobAdmission.review(job) {
        case let .rejected(rejection):
            let delivery: JobReportDelivery = try await reporter.report(Self.report(of: rejection), to: target)
            return .init(disposition: .refused(jobIdentifier: job.id, delivery: delivery), cursor: result.lastUpdate)
        case let .accepted(plan):
            let runner: JobRunner = .init(backend: backend, configuration: configuration.runner)
            let report: JobRunReport = await runner.run(plan, on: configuration.image)
            let delivery: JobReportDelivery = try await reporter.report(report, to: target)
            return .init(
                disposition: .handled(jobIdentifier: job.id, outcome: report.outcome, delivery: delivery),
                cursor: result.lastUpdate
            )
        }
    }

    /// 一直領到被喊停。
    ///
    /// 領件那一步失敗不結束迴圈：站台不在、網路斷一下都屬於「等一下再試」，就地退出會讓這台
    /// runner 從此不再出現在站台的候選裡，而沒有任何人會發現。
    ///
    /// **喊停最慢會等到當下這一輪走完**：領件是 long-poll，站台端最長 hold 到五十秒左右；跑到
    /// 一半的 job 更不能從中間丟下——那會留下一台沒人收的 guest，以及站台端一件永遠停在執行中
    /// 的 job。
    ///
    /// - Parameters:
    ///   - cursor: 起始游標；預設 nil。
    ///   - stopAfterFirstJob: 經手完一件 job（含拒收）就結束。
    ///   - isStopped: 每一輪開始前問一次要不要停。
    ///   - log: 一行一件事的紀錄出口；**這條路徑不帶任何 token**。
    public func run(
        startingAt cursor: String? = nil,
        stopAfterFirstJob: Bool,
        isStopped: @Sendable () -> Bool,
        log: @Sendable (String) -> Void
    ) async {
        var currentCursor: String? = cursor
        while !isStopped() {
            let cycle: JobCycle
            do {
                cycle = try await poll(cursor: currentCursor)
            } catch {
                // 錯誤本身可以照印：協議層的錯誤型別已經把站台網址收斂成 scheme／host／port，
                // 不會把嵌在網址裡的憑證帶出來。
                log("poll failed: \(error)")
                await wait(configuration.retryInterval)
                continue
            }
            currentCursor = cycle.cursor
            log(Self.summary(of: cycle.disposition))
            if stopAfterFirstJob, cycle.didHandleJob { return }
        }
    }

    /// 真的睡指定秒數；取消時直接回來，由呼叫端的停止旗標決定下一步。
    ///
    /// - Parameter seconds: 要睡多久。
    public static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// 把一次拒收轉成要回寫給站台的那份結果。
    ///
    /// 結果類別取「job 失敗」而不是「系統失敗」：拒收的失敗分類固定是「程式錯、不重試」
    /// （見 ``JobAdmission/Rejection/failureReason``），而本側的「系統失敗」在紀錄上讀作
    /// 可重試——兩者放在同一份結果裡會自相矛盾，事後查 log 與查站台會得到相反的結論。
    ///
    /// - Parameter rejection: 拒收的內容。
    /// - Returns: 帶著拒收理由的結果；trace 已過遮蔽。
    private static func report(of rejection: JobAdmission.Rejection) -> JobRunReport {
        .init(outcome: .jobFailed, failureReason: rejection.failureReason, trace: rejection.traceMessage)
    }

    /// 把一輪的處置寫成一行紀錄。
    ///
    /// - Parameter disposition: 這一輪的處置。
    /// - Returns: 一行紀錄；不含任何 payload 衍生字串。
    private static func summary(of disposition: JobCycle.Disposition) -> String {
        switch disposition {
        case .idle:
            "no job available"
        case let .handled(identifier, outcome, delivery):
            "job \(identifier) outcome=\(outcome.rawValue) acceptance=\(delivery.acceptance.rawValue) "
                + "traceComplete=\(delivery.traceIsComplete)"
        case let .refused(identifier, delivery):
            "job \(identifier) refused acceptance=\(delivery.acceptance.rawValue)"
        }
    }
}
