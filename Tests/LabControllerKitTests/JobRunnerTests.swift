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

/// 以結束碼與標準輸出組一個結果；命令本身不影響斷言，故填佔位值。
private func result(_ exitCode: Int32, output: String = "") -> CommandResult {
    .init(command: ["scripted"], exitCode: exitCode, standardOutput: .init(output.utf8))
}

private final class JobRunnerTests {

    /// 測試共用的基底。
    private let image: GuestImage = .alias("ci-linux")

    /// 測試共用的取碼座標。
    private let git: GitInfo = .init(repoURL: "https://gitlab.example/group/project.git", ref: "main", sha: "deadbeef")

    // MARK: - 成功路徑

    /// 全部步驟綠燈時判完成，收尾把環境焚毀。
    @Test
    func `completes a job whose steps all succeed`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            git: git,
            steps: [.init(name: "script", script: ["swift build"])],
            timeoutSeconds: 600
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.outcome == .completed)
        #expect(report.failureReason == nil)
        #expect(report.exitCode == 0)
        #expect(backend.destroyCount == 1)
        #expect(try await backend.ps().isEmpty)
    }

    /// 跑的是鋪好的腳本、而不是由本側拼出來的命令列。
    @Test
    func `runs the rendered scripts through the configured shell`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let plan: JobPlan = .init(jobIdentifier: 1, steps: [.init(name: "script", script: ["swift build"])],
                                  timeoutSeconds: 600)
        _ = await JobRunner(backend: backend).run(plan, on: image)
        #expect(backend.executedCommands == [["/bin/bash", "-l", "/tmp/labcontroller/steps/step-0.sh"]])
    }

    /// 變數與腳本在環境開起來時就位，不靠事後再送一次。
    @Test
    func `places the workspace in the guest at spawn`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [.init(name: "script", script: ["swift build"])],
            environment: [.init(key: "CI_PROJECT_PATH", value: "group/project")],
            timeoutSeconds: 600
        )
        let observing: ObservingBackend = .init(inner: backend)
        _ = await JobRunner(backend: observing).run(plan, on: image)
        #expect(observing.injectedPaths == ["/tmp/labcontroller/env.sh", "/tmp/labcontroller/steps/step-0.sh"])
    }

    /// 預算用完的那次判定不掛在任何一個結束碼上。
    @Test
    func `reports no exit code when the budget runs out before any failure`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let clock: SteppingClock = .init(step: 45)
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [
                .init(name: "script", script: ["swift build"]),
                .init(name: "release", script: ["publish"]),
            ],
            timeoutSeconds: 60
        )
        let report: JobRunReport = await JobRunner(backend: backend, now: clock.now).run(plan, on: image)
        #expect(report.outcome == .timeout)
        #expect(report.exitCode == nil)
    }

    // MARK: - 失敗路徑

    /// 步驟紅了就是 job 錯、不重試，且帶回第一個失敗的結束碼。
    @Test
    func `fails the job when a required step exits non-zero`() async throws {
        let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
            command.last?.hasSuffix("step-0.sh") == true ? result(3, output: "boom") : nil
        }))
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [.init(name: "script", script: ["swift build"])],
            timeoutSeconds: 600
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.outcome == .jobFailed)
        #expect(report.failureReason == .scriptFailure)
        #expect(report.exitCode == 3)
        #expect(report.trace.contains("boom"))
    }

    /// 失敗之後，`on_success` 的步驟略過、`always` 的照跑——`after_script` 靠這條收拾現場。
    @Test
    func `skips on-success steps after a failure but still runs the always ones`() async throws {
        let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
            command.last?.hasSuffix("step-0.sh") == true ? result(1) : nil
        }))
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [
                .init(name: "script", script: ["swift build"]),
                .init(name: "release", script: ["publish"]),
                .init(name: "after_script", script: ["cleanup"], runCondition: .always),
            ],
            timeoutSeconds: 600
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        let scripts: [String] = backend.executedCommands.compactMap(\.last)
        #expect(scripts == ["/tmp/labcontroller/steps/step-0.sh", "/tmp/labcontroller/steps/step-2.sh"])
        #expect(report.outcome == .jobFailed)
    }

    /// 允許失敗的步驟紅了不讓整個 job 紅。
    @Test
    func `keeps the job green when a step that may fail exits non-zero`() async throws {
        let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
            command.last?.hasSuffix("step-0.sh") == true ? result(2) : nil
        }))
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [.init(name: "after_script", script: ["cleanup"], allowFailure: true, runCondition: .always)],
            timeoutSeconds: 600
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.outcome == .completed)
        #expect(report.exitCode == 0)
    }

    /// 取不到碼算環境錯（站台端會重試），且一個步驟都不跑。
    @Test
    func `reports a system failure when the checkout does not succeed`() async throws {
        let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
            command.last?.hasSuffix("checkout.sh") == true ? result(128, output: "fatal: repository not found") : nil
        }))
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            git: git,
            steps: [.init(name: "script", script: ["swift build"])],
            timeoutSeconds: 600
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.outcome == .systemFailed)
        #expect(report.failureReason == .runnerSystemFailure)
        #expect(backend.executedCommands.count == 1)
        #expect(backend.destroyCount == 1)
    }

    /// 後端自己沒把事情做成時收成系統層失敗，環境不留在那裡。
    @Test
    func `reports a system failure when the backend cannot run the command`() async throws {
        let backend: FailingExecutionBackend = .init()
        let plan: JobPlan = .init(jobIdentifier: 1, steps: [.init(name: "script", script: ["swift build"])],
                                  timeoutSeconds: 600)
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.outcome == .systemFailed)
        #expect(report.failureReason == .runnerSystemFailure)
        #expect(backend.destroyCount == 1)
    }

    /// 變數名說不通時連環境都不開——擋在這裡，收拾成本最低。
    @Test
    func `stops before opening a guest when the workspace cannot be rendered`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            environment: [.init(key: "LABCTL_SHA", value: "deadbeef")],
            timeoutSeconds: 600
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.outcome == .systemFailed)
        #expect(report.failureReason == .runnerSystemFailure)
        #expect(backend.executedCommands.isEmpty)
        #expect(try await backend.ps().isEmpty)
    }

    // MARK: - 時間上限

    /// 預算用完之後不再開始新的步驟。
    @Test
    func `stops starting steps once the budget is spent`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let clock: SteppingClock = .init(step: 45)
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [
                .init(name: "script", script: ["swift build"]),
                .init(name: "release", script: ["publish"]),
            ],
            timeoutSeconds: 60
        )
        let runner: JobRunner = .init(backend: backend, now: clock.now)
        let report: JobRunReport = await runner.run(plan, on: image)
        #expect(report.outcome == .timeout)
        #expect(report.failureReason == .jobExecutionTimeout)
        #expect(backend.executedCommands.count == 1)
        #expect(backend.destroyCount == 1)
    }

    /// 已經有步驟失敗過之後才撞到上限時，死因維持那個失敗、不換成逾時。
    @Test
    func `keeps the script failure as the cause when the budget runs out afterwards`() async throws {
        let backend: InMemoryExecutionBackend = .init(script: .init(handler: { command in
            command.last?.hasSuffix("step-0.sh") == true ? result(4) : nil
        }))
        let clock: SteppingClock = .init(step: 45)
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [
                .init(name: "script", script: ["swift build"]),
                .init(name: "after_script", script: ["cleanup"], runCondition: .always),
            ],
            timeoutSeconds: 60
        )
        let runner: JobRunner = .init(backend: backend, now: clock.now)
        let report: JobRunReport = await runner.run(plan, on: image)
        #expect(report.outcome == .jobFailed)
        #expect(report.failureReason == .scriptFailure)
        #expect(report.exitCode == 4)
    }

    // MARK: - 收拾

    /// 焚毀失敗不改寫已經跑完的那份結果：把做完的 job 說成可重試，站台端會整件重跑一次。
    @Test
    func `keeps the finished result when the guest cannot be destroyed`() async throws {
        let backend: InMemoryExecutionBackend = .init(script: .init(destroyError: .backendUnavailable(detail: "gone")))
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [.init(name: "script", script: ["swift build"])],
            timeoutSeconds: 600
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.outcome == .completed)
        #expect(report.failureReason == nil)
        #expect(report.trace.contains("環境沒能焚毀"))
    }

    // MARK: - trace

    /// 遮蔽變數的值不得出現在 trace 裡，即使它是命令自己印出來的。
    @Test
    func `masks secret values that a command prints`() async throws {
        let backend: InMemoryExecutionBackend = .init(script: .init(handler: { _ in
            result(0, output: "using glrt-super-secret-token to authenticate")
        }))
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [.init(name: "script", script: ["deploy"])],
            environment: [.init(key: "TOKEN", value: "glrt-super-secret-token", masked: true)],
            masker: .init(maskedValues: ["glrt-super-secret-token"]),
            timeoutSeconds: 600
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.trace.contains("glrt-super-secret-token") == false)
        #expect(report.trace.contains(TraceMasker.maskToken))
    }

    /// 降級掉的能力必須說出來：略過一件 CI 檔要求的事而不留痕，事後無從查起。
    @Test
    func `writes skipped capabilities into the trace`() async throws {
        let backend: InMemoryExecutionBackend = .init()
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [.init(name: "script", script: ["swift build"])],
            timeoutSeconds: 600,
            warnings: [.cache(count: 2)]
        )
        let report: JobRunReport = await JobRunner(backend: backend).run(plan, on: image)
        #expect(report.warnings == [.cache(count: 2)])
        #expect(report.trace.contains("cache"))
    }
}
