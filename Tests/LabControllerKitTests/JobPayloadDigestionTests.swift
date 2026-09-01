//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LabControllerKit
import Testing

/// 把 JSON 字面解成 `JobResponse`；解不出即測試失敗。
private func decodeJob(_ json: String) throws -> JobResponse {
    try JSONDecoder().decode(JobResponse.self, from: Data(json.utf8))
}

/// payload 新增欄位的解碼行為。
private final class JobPayloadDecodingTests {

    /// 步驟解出 `timeout` 與 `when`；`after_script` 的 `always` 必須原樣帶出來。
    @Test
    func `steps decode timeout and run condition`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","steps":[
          {"name":"script","script":["make"],"timeout":3600,"when":"on_success","allow_failure":false},
          {"name":"after_script","script":["cleanup"],"timeout":3600,"when":"always","allow_failure":true}
        ]}
        """#)
        #expect(job.steps.count == 2)
        #expect(job.steps.first?.timeoutSeconds == 3600)
        #expect(job.steps.first?.runCondition == .onSuccess)
        #expect(job.steps.last?.runCondition == .always)
        #expect(job.steps.last?.allowFailure == true)
    }

    /// 未知的 `when` 值不得讓整包 payload 解不開——那會讓已指派的 job 被丟掉；
    /// 但原字串必須留著，回落值不可以被當成站台真的這樣說。
    @Test
    func `unknown run condition is kept instead of throwing`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","steps":[{"name":"script","script":["x"],"when":"on_moon_phase"}]}
        """#)
        #expect(job.steps.first?.runCondition == .onSuccess)
        #expect(job.steps.first?.unrecognisedRunCondition == "on_moon_phase")
        #expect(job.unreadableFields == ["steps[].when"])
    }

    /// 認得的 `when` 不留殘值，也不得誤記進讀不懂的欄位。
    @Test
    func `known run condition leaves no residue`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","steps":[{"name":"after_script","script":["x"],"when":"always"}]}
        """#)
        #expect(job.steps.first?.runCondition == .always)
        #expect(job.steps.first?.unrecognisedRunCondition == nil)
        #expect(job.unreadableFields.isEmpty)
    }

    /// `runner_info.timeout` 解得出來；缺席時為 nil 而非 0，讓政策層分得出「沒說」。
    @Test
    func `runner info timeout decodes and stays absent when omitted`() throws {
        let withInfo: JobResponse = try decodeJob(#"{"id":1,"token":"t","runner_info":{"timeout":900}}"#)
        #expect(withInfo.runnerInfo?.timeoutSeconds == 900)
        let without: JobResponse = try decodeJob(#"{"id":1,"token":"t"}"#)
        #expect(without.runnerInfo == nil)
    }

    /// 未宣告的能力欄位（缺席或 null）一律數成 0，不得誤判成「有宣告」。
    @Test
    func `absent and null capability fields count as zero`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","image":null,"services":null,"artifacts":null,"cache":null}
        """#)
        #expect(job.imageName == nil)
        #expect(job.serviceCount == 0)
        #expect(job.artifactCount == 0)
        #expect(job.cacheCount == 0)
    }

    /// 有宣告時數得出筆數與 image 名稱。
    @Test
    func `declared capability fields are counted`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","image":{"name":"synthetic:latest"},
         "services":[{"name":"a"},{"name":"b"}],
         "artifacts":[{"name":"logs","paths":["out"]}],
         "cache":[{"key":"k","paths":["deps"]}]}
        """#)
        #expect(job.imageName == "synthetic:latest")
        #expect(job.serviceCount == 2)
        #expect(job.artifactCount == 1)
        #expect(job.cacheCount == 1)
    }

    /// 上游相依只有帶 `artifacts_file` 者才算「有產物」。
    @Test
    func `dependency carries artifacts only when file present`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","dependencies":[
          {"id":10,"name":"lint"},
          {"id":11,"name":"build","artifacts_file":{"filename":"artifacts.zip","size":42}}
        ]}
        """#)
        #expect(job.dependencies.count == 2)
        #expect(job.dependencies.first?.carriesArtifacts == false)
        #expect(job.dependencies.last?.carriesArtifacts == true)
        #expect(job.dependencies.last?.artifactsFile?.filename == "artifacts.zip")
    }

    /// 空檔名**仍算有產物**：站台只在真的有產物時才送這個物件，讀不出檔名是我們的問題，
    /// 不能拿來當「那就沒有吧」的理由——那條路的終點是 job 回綠但產物沒下載。
    @Test
    func `empty artifact filename still counts as artifacts`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","dependencies":[{"id":9,"name":"x","artifacts_file":{"filename":"","size":0}}]}
        """#)
        #expect(job.dependencies.first?.carriesArtifacts == true)
        #expect(job.dependencies.first?.hasUnreadableArtifactsFilename == true)
        #expect(job.unreadableFields == ["dependencies[].artifacts_file.filename"])
    }

    /// 值為 null 的變數解成空字串：站台每次都會送至少一個這種變數，拋錯等於一件也接不了。
    @Test
    func `variable with a null value decodes as empty`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","variables":[
          {"key":"CI_PROJECT_CLASSIFICATION_LABEL","value":null,"masked":false,"public":true},
          {"key":"CI_PROJECT_PATH","value":"group/app","masked":false}
        ]}
        """#)
        #expect(job.variables.count == 2)
        #expect(job.variables.first?.key == "CI_PROJECT_CLASSIFICATION_LABEL")
        #expect(job.variables.first?.value == "")
        #expect(job.variables.last?.value == "group/app")
        #expect(job.unreadableFields.isEmpty)
    }

    /// 沒有 `value` 鍵與值為 null 同義；兩者都不得讓變數本身消失。
    @Test
    func `variable without a value key decodes as empty`() throws {
        let job: JobResponse = try decodeJob(#"{"id":1,"token":"t","variables":[{"key":"EMPTY"}]}"#)
        #expect(job.variables.first?.key == "EMPTY")
        #expect(job.variables.first?.value == "")
        #expect(job.unreadableFields.isEmpty)
    }

    /// 一個變數讀不懂不得拖垮其餘的：壞的那個記名字，好的那些照常帶出來。
    @Test
    func `unreadable variable is named without dropping the rest`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","variables":[
          {"key":"CI_PROJECT_PATH","value":"group/app"},
          {"key":"CI_ODDITY","value":{"nested":"shape"}},
          {"key":"CI_COMMIT_SHA","value":"abc"}
        ]}
        """#)
        #expect(job.variables.map(\.key) == ["CI_PROJECT_PATH", "CI_COMMIT_SHA"])
        #expect(job.unreadableFields == ["variables[CI_ODDITY]"])
    }

    /// 連名稱都讀不出來時記序號，序號指的是它在站台送來的陣列裡的位置。
    @Test
    func `unreadable variable without a name is recorded by position`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","variables":[{"key":"A","value":"1"},42,{"key":"B","value":"2"}]}
        """#)
        #expect(job.variables.map(\.key) == ["A", "B"])
        #expect(job.unreadableFields == ["variables[#1]"])
    }

    /// 整個 `variables` 不是陣列時仍記整個欄位名，與其他欄位同形。
    @Test
    func `variables of the wrong shape are recorded as one field`() throws {
        let job: JobResponse = try decodeJob(#"{"id":1,"token":"t","variables":"CI_PROJECT_PATH=group/app"}"#)
        #expect(job.variables.isEmpty)
        #expect(job.unreadableFields == ["variables"])
    }

    /// 讀不懂的變數要擋下這件 job：其餘變數還在，不代表這件事可以照跑。
    @Test
    func `unreadable variable blocks admission`() {
        let job: JobResponse = .init(id: 1, token: "t", unreadableFields: ["variables[CI_ODDITY]"])
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("讀不懂的變數必須擋下收件")
            return
        }
        #expect(rejection.features == [.unreadablePayloadField(name: "variables[CI_ODDITY]")])
    }

    /// 能力欄位形狀變了不得讓整包解不出來——那會讓已指派的 job 靜靜消失。
    @Test
    func `unexpected capability shape is recorded instead of throwing`() throws {
        let job: JobResponse = try decodeJob(#"{"id":7,"token":"t","cache":{"key":"k"}}"#)
        #expect(job.id == 7)
        #expect(job.unreadableFields == ["cache"])
        #expect(job.cacheCount == 0)
    }

    /// 任何一個非 id／token 欄位形狀變了都走同一條路，不是只有能力欄位有保護。
    @Test
    func `unexpected shape on other fields is also recorded`() throws {
        let job: JobResponse = try decodeJob(#"{"id":7,"token":"t","steps":"make","runner_info":42}"#)
        #expect(job.steps.isEmpty)
        #expect(job.runnerInfo == nil)
        #expect(job.unreadableFields == ["steps", "runner_info"])
    }

    /// 送了 image 物件卻沒帶名字時仍算「宣告了 image」，不得因為名字是空的就當沒看到。
    @Test
    func `image object without a name still counts as declared`() throws {
        #expect(try decodeJob(#"{"id":1,"token":"t","image":{}}"#).imageName == "")
        #expect(try decodeJob(#"{"id":1,"token":"t","image":{"name":""}}"#).imageName == "")
    }

    /// 有 `git_info` 卻缺 `repo_url`：clone 做不到，必須在收件時就說，不是留到執行階段炸。
    @Test
    func `incomplete git coordinates are recorded`() throws {
        let job: JobResponse = try decodeJob(#"{"id":1,"token":"t","git_info":{"ref":"main","sha":"abc"}}"#)
        #expect(job.gitInfo?.hasIncompleteCoordinates == true)
        #expect(job.unreadableFields == ["git_info.repo_url/sha"])
    }

    /// 座標齊全時不得誤報。
    @Test
    func `complete git coordinates are not flagged`() throws {
        let job: JobResponse = try decodeJob(#"""
        {"id":1,"token":"t","git_info":{"repo_url":"https://example.invalid/g/a.git","ref":"main","sha":"abc"}}
        """#)
        #expect(job.gitInfo?.hasIncompleteCoordinates == false)
        #expect(job.unreadableFields.isEmpty)
    }

    /// `image` 形狀讀不懂時只記 unreadable，不另外編一個名字出來誤導 trace。
    @Test
    func `unreadable image shape reports only the field`() throws {
        let job: JobResponse = try decodeJob(#"{"id":1,"token":"t","image":"synthetic:1.0"}"#)
        #expect(job.imageName == nil)
        #expect(job.unreadableFields == ["image"])
    }

    /// 短於下限的遮蔽值不遮，但「有值沒遮」這件事本身要看得見。
    @Test
    func `dropped short masked values are counted`() {
        let job: JobResponse = .init(
            id: 1,
            token: "synthetic-job-token",
            variables: [
                .init(key: "SHORT", value: "ab", masked: true),
                .init(key: "LONG", value: "synthetic-secret-value", masked: true)
            ]
        )
        guard case let .accepted(plan) = JobAdmission.review(job) else {
            Issue.record("預期 accepted")
            return
        }
        #expect(plan.masker.phraseCount == 2)
        #expect(plan.masker.droppedPhraseCount == 1)
        // 只記在 masker 裡等於沒人看得到——要落到 trace 上才算「說出來了」。
        #expect(plan.warnings == [.unmaskedShortValues(count: 1)])
    }

    /// 上游名字讀不出來時退回識別碼，別讓 trace 印成「上游 job（）」。
    @Test
    func `dependency without a name falls back to its identifier`() {
        let job: JobResponse = .init(
            id: 1,
            token: "synthetic-job-token",
            dependencies: [.init(identifier: 42, name: "", artifactsFile: .init(filename: "out.zip", size: 8))]
        )
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.features == [.dependencyArtifacts(jobNames: ["#42"])])
    }

    /// 擋門要建在做決定的那一關：直接造出帶殘值的 step 也必須被擋下。
    @Test
    func `unrecognised run condition blocks admission even without the decoder`() {
        let job: JobResponse = .init(
            id: 1,
            token: "synthetic-job-token",
            steps: [.init(name: "script", script: ["x"], unrecognisedRunCondition: "on_moon_phase")]
        )
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.features == [.unreadablePayloadField(name: "steps[].when")])
    }
}

/// 收件判定（`JobAdmission`）的行為。
private final class JobAdmissionTests {

    /// 乾淨的 payload 收下，變數依 `file` 旗標分成環境與檔案兩堆。
    @Test
    func `clean payload is accepted and splits file variables`() {
        let job: JobResponse = .init(
            id: 5,
            token: "synthetic-job-token",
            variables: [
                .init(key: "CI_PROJECT_PATH", value: "group/app"),
                .init(key: "DEPLOY_KEY", value: "synthetic-secret-value", masked: true, file: true)
            ],
            steps: [.init(name: "script", script: ["make"])],
            runnerInfo: .init(timeoutSeconds: 600)
        )
        guard case let .accepted(plan) = JobAdmission.review(job) else {
            Issue.record("預期 accepted")
            return
        }
        #expect(plan.jobIdentifier == 5)
        #expect(plan.environment.map(\.key) == ["CI_PROJECT_PATH"])
        #expect(plan.fileVariables.map(\.key) == ["DEPLOY_KEY"])
        #expect(plan.timeoutSeconds == 600)
        #expect(plan.warnings.isEmpty)
        // masked 的值不論走環境還是檔案，都要進遮蔽片語；job token 沒有旗標可依靠，
        // 但它會經由 git_info.repo_url 的 userinfo 走進 trace，一律無條件遮。
        #expect(plan.masker.phrases.sorted() == ["synthetic-job-token", "synthetic-secret-value"])
    }

    /// 拒收訊息也要過遮蔽：站台可能對 `image:` 做過變數展開，秘密會落在訊息第一行。
    @Test
    func `rejection message is masked`() {
        let job: JobResponse = .init(
            id: 1,
            token: "t",
            variables: [.init(key: "REGISTRY", value: "synthetic-secret-host", masked: true)],
            imageName: "synthetic-secret-host/app:1.0"
        )
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(!rejection.traceMessage.contains("synthetic-secret-host"))
        #expect(rejection.traceMessage.contains("[MASKED]"))
    }

    /// 未知的 `when` 值擋下整個 job——回落成 `on_success` 會讓步驟跑在錯的結果分支上。
    @Test
    func `unrecognised run condition blocks admission`() {
        let job: JobResponse = .init(id: 1, token: "t", unreadableFields: ["steps[].when"])
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.features == [.unreadablePayloadField(name: "steps[].when")])
    }

    /// 宣告 services 直接拒收，訊息指名是 services、失敗分類為不重試。
    @Test
    func `services declaration is rejected as non retryable`() {
        let job: JobResponse = .init(id: 1, token: "t", serviceCount: 1)
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.features == [.services(count: 1)])
        #expect(rejection.failureReason == .scriptFailure)
        #expect(rejection.traceMessage.contains("services"))
    }

    /// 宣告 artifacts 必須紅——回綠等於「綠了但產物沒存」。
    @Test
    func `artifacts declaration is rejected`() {
        let job: JobResponse = .init(id: 1, token: "t", artifactCount: 2)
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.features == [.artifacts(count: 2)])
    }

    /// image 宣告拒收，訊息帶出是哪個 image。
    @Test
    func `image declaration is rejected with its name`() {
        let job: JobResponse = .init(id: 1, token: "t", imageName: "synthetic:1.0")
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.traceMessage.contains("synthetic:1.0"))
    }

    /// 有上游但沒有產物＝正常的多 stage pipeline，不得因此拒收。
    @Test
    func `dependencies without artifacts do not block admission`() {
        let job: JobResponse = .init(
            id: 1,
            token: "t",
            dependencies: [.init(identifier: 9, name: "lint"), .init(identifier: 10, name: "unit")]
        )
        guard case .accepted = JobAdmission.review(job) else {
            Issue.record("預期 accepted：有上游不等於有產物要下載")
            return
        }
    }

    /// 上游帶產物才拒收，並指名是哪些 job。
    @Test
    func `dependencies carrying artifacts are rejected`() {
        let job: JobResponse = .init(
            id: 1,
            token: "t",
            dependencies: [
                .init(identifier: 9, name: "lint"),
                .init(identifier: 10, name: "build", artifactsFile: .init(filename: "out.zip", size: 8))
            ]
        )
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.features == [.dependencyArtifacts(jobNames: ["build"])])
        #expect(!rejection.traceMessage.contains("lint"))
    }

    /// cache 是唯一允許降級的欄位：照收、但警告要帶進計劃。
    @Test
    func `cache declaration downgrades to warning`() {
        let job: JobResponse = .init(id: 1, token: "t", cacheCount: 3)
        guard case let .accepted(plan) = JobAdmission.review(job) else {
            Issue.record("預期 accepted：cache 缺席只影響速度")
            return
        }
        #expect(plan.warnings == [.cache(count: 3)])
        #expect(UnsupportedJobFeature.cache(count: 3).severity == .warning)
    }

    /// 讀不懂的欄位一律擋下，並在訊息裡指名是哪個欄位。
    @Test
    func `unreadable payload field blocks admission`() {
        let job: JobResponse = .init(id: 1, token: "t", unreadableFields: ["cache"])
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected：形狀讀不懂就無從判斷它宣告了什麼")
            return
        }
        #expect(rejection.features == [.unreadablePayloadField(name: "cache")])
        #expect(rejection.traceMessage.contains("cache"))
        #expect(UnsupportedJobFeature.unreadablePayloadField(name: "cache").severity == .fatal)
    }

    /// image 物件沒帶名字時照樣拒收——「名字是空的」不等於「沒要求容器」。
    @Test
    func `image declared without a name is still rejected`() {
        let job: JobResponse = .init(id: 1, token: "t", imageName: "")
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.features == [.image(name: "")])
    }

    /// 多項缺口一次全列出來，不是報第一個就停。
    @Test
    func `every blocking feature is reported`() {
        let job: JobResponse = .init(id: 1, token: "t", imageName: "x", serviceCount: 1, artifactCount: 1)
        guard case let .rejected(rejection) = JobAdmission.review(job) else {
            Issue.record("預期 rejected")
            return
        }
        #expect(rejection.features.count == 3)
        #expect(rejection.traceMessage.split(separator: "\n").count == 3)
    }
}

/// 逾時夾制（`JobTimeoutPolicy`）的行為。
private final class JobTimeoutPolicyTests {

    /// 站台宣告值小於硬上限時照用。
    @Test
    func `declared timeout below the cap is honoured`() {
        let policy: JobTimeoutPolicy = .init(hardLimitSeconds: 1800)
        #expect(policy.effectiveSeconds(declaredSeconds: 600) == 600)
    }

    /// 站台宣告值超過硬上限一律夾掉——CI 檔可以自己寫 3h，執行池不能配合。
    @Test
    func `declared timeout above the cap is clamped`() {
        let policy: JobTimeoutPolicy = .init(hardLimitSeconds: 1800)
        #expect(policy.effectiveSeconds(declaredSeconds: 10_800) == 1800)
    }

    /// 沒宣告或宣告非正值＝回落硬上限，不是無上限。
    @Test
    func `absent or non positive timeout falls back to the cap`() {
        let policy: JobTimeoutPolicy = .init(hardLimitSeconds: 1800)
        #expect(policy.effectiveSeconds(declaredSeconds: nil) == 1800)
        #expect(policy.effectiveSeconds(declaredSeconds: 0) == 1800)
        #expect(policy.effectiveSeconds(declaredSeconds: -1) == 1800)
    }

    /// 硬上限設成非正值時夾成 1 秒，不得靜默變成無上限。
    @Test
    func `non positive hard limit is clamped to one second`() {
        #expect(JobTimeoutPolicy(hardLimitSeconds: 0).hardLimitSeconds == 1)
    }

    /// 站台宣告值會被本機上限夾住，即使 payload 說得再大。
    @Test
    func `admission applies the policy to the declared timeout`() {
        let job: JobResponse = .init(id: 1, token: "t", runnerInfo: .init(timeoutSeconds: 10_800))
        guard case let .accepted(plan) = JobAdmission.review(job, timeoutPolicy: .init(hardLimitSeconds: 900)) else {
            Issue.record("預期 accepted")
            return
        }
        #expect(plan.timeoutSeconds == 900)
    }

    /// 步驟宣告的逾時也要夾——只夾 job 級那一個，執行端照步驟值跑就繞過了硬上限。
    @Test
    func `step timeouts are clamped to the job budget`() {
        let job: JobResponse = .init(
            id: 1,
            token: "t",
            steps: [
                .init(name: "script", script: ["make"], timeoutSeconds: 10_800),
                .init(name: "after_script", script: ["cleanup"], timeoutSeconds: 300),
                .init(name: "unset", script: ["x"])
            ],
            runnerInfo: .init(timeoutSeconds: 10_800)
        )
        guard case let .accepted(plan) = JobAdmission.review(job, timeoutPolicy: .init(hardLimitSeconds: 900)) else {
            Issue.record("預期 accepted")
            return
        }
        #expect(plan.timeoutSeconds == 900)
        // 超過預算的夾成預算、原本就在預算內的不動、未宣告（0）維持 0 讓執行端回落 job 預算。
        #expect(plan.steps.map(\.timeoutSeconds) == [900, 300, 0])
    }

    /// 負的步驟逾時歸零＝回落「未宣告」；帶著它往下走，執行端轉無號時距會變成近乎無限。
    @Test
    func `negative step timeout falls back to unset`() {
        let job: JobResponse = .init(
            id: 1,
            token: "t",
            steps: [.init(name: "script", script: ["make"], timeoutSeconds: -5)]
        )
        guard case let .accepted(plan) = JobAdmission.review(job, timeoutPolicy: .init(hardLimitSeconds: 600)) else {
            Issue.record("預期 accepted")
            return
        }
        #expect(plan.steps.map(\.timeoutSeconds) == [0])
    }
}

/// 步驟執行條件（`JobStepWhen`）的判斷。
private final class JobStepWhenTests {

    /// `on_success` 只在還沒失敗時跑。
    @Test
    func `on success runs only before any failure`() {
        #expect(JobStepWhen.onSuccess.shouldRun(afterFailure: false))
        #expect(!JobStepWhen.onSuccess.shouldRun(afterFailure: true))
    }

    /// `on_failure` 反過來。
    @Test
    func `on failure runs only after a failure`() {
        #expect(!JobStepWhen.onFailure.shouldRun(afterFailure: false))
        #expect(JobStepWhen.onFailure.shouldRun(afterFailure: true))
    }

    /// `always` 兩種情況都跑——`after_script` 能在失敗後收拾現場靠的就是這個。
    @Test
    func `always runs in both cases`() {
        #expect(JobStepWhen.always.shouldRun(afterFailure: false))
        #expect(JobStepWhen.always.shouldRun(afterFailure: true))
    }
}
