//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 領到的 job 收不收；不收時附上要寫進 trace 的理由與回報用的失敗分類。
///
/// 這一關刻意擋在執行之前：payload 裡缺的能力在第一眼就看得出來，等跑到一半才發現，
/// 已經燒掉一個執行格、還多出一份要收拾的半成品。
public enum JobAdmission: Sendable, Equatable {

    /// 收下，附消化過的執行計劃。
    case accepted(JobPlan)

    /// 不收，直接回報失敗。
    case rejected(Rejection)

    /// 拒收的內容。
    public struct Rejection: Sendable, Equatable {

        /// 造成拒收的每一項缺口。
        public let features: [UnsupportedJobFeature]

        /// 寫進 trace 前要套的遮蔽規則。
        ///
        /// 拒收路徑也要遮：`traceMessage` 會把 payload 衍生的字串（image 名、上游 job 名）
        /// 內插進去，而站台端對這些欄位可能已經做過變數展開——`image: $PRIVATE_REGISTRY`
        /// 這種寫法會讓一個 masked 值出現在拒收訊息的第一行。把遮蔽做成結構保證，不要靠
        /// 「這條路徑應該不會有秘密」的慣例。
        public let masker: TraceMasker

        /// 以缺口清單建立。
        public init(features: [UnsupportedJobFeature], masker: TraceMasker = .init(maskedValues: [])) {
            self.features = features
            self.masker = masker
        }

        /// 回報給站台的失敗分類。
        ///
        /// 固定為「程式錯、不重試」：缺的是本 executor 的能力，重跑幾次結果都一樣。
        /// 標成可重試只會讓同一個 job 白佔執行格好幾輪，然後以同樣的理由再失敗一次。
        public var failureReason: JobFailureReason {
            .scriptFailure
        }

        /// 寫進 trace 的完整說明；逐項列出缺了什麼，一項一行，且已過遮蔽。
        public var traceMessage: String {
            masker.mask(features.map(\.traceMessage).joined(separator: "\n"))
        }
    }

    /// 檢視 payload，決定收或不收。
    ///
    /// 警告級的缺口（cache）不影響收件，但會原樣帶進 `JobPlan.warnings` 等執行端寫進
    /// trace——降級可以，靜默不行。
    public static func review(
        _ job: JobResponse,
        timeoutPolicy: JobTimeoutPolicy = .init()
    ) -> JobAdmission {
        let features: [UnsupportedJobFeature] = unsupportedFeatures(in: job)
        let masker: TraceMasker = .init(variables: job.variables, jobToken: job.token)
        let blocking: [UnsupportedJobFeature] = features.filter { $0.severity == .fatal }
        guard blocking.isEmpty else { return .rejected(.init(features: blocking, masker: masker)) }
        let budget: Int = timeoutPolicy.effectiveSeconds(declaredSeconds: job.runnerInfo?.timeoutSeconds)
        return .accepted(
            .init(
                jobIdentifier: job.id,
                git: job.gitInfo,
                steps: clamped(job.steps, toSeconds: budget),
                environment: job.variables.filter { !$0.file },
                fileVariables: job.variables.filter(\.file),
                masker: masker,
                timeoutSeconds: budget,
                warnings: features.filter { $0.severity == .warning }
            )
        )
    }

    /// 把每個步驟宣告的逾時夾進本次 job 的預算內。
    ///
    /// 不夾的話 `JobPlan` 會同時帶著「已夾的 job 逾時」與「未夾的步驟逾時」兩個互相打架的
    /// 數字——執行端照步驟值跑就直接突破了本機硬上限，而那個上限存在的理由（一個跑飛的 job
    /// 佔住執行格）完全沒有因為它寫在步驟層就消失。16.2 給每個步驟的本來就是同一個 job 級
    /// 逾時的複本，夾成同一個值不會少跑任何東西。
    ///
    /// `0` 維持原樣＝站台未宣告，執行端回落 job 逾時；**負值一律歸零**——它既不是「未宣告」
    /// 也不在預算內，帶著它往下走，執行端把它轉成無號時距時會變成近乎無限，正好繞過這裡。
    private static func clamped(_ steps: [JobStep], toSeconds budget: Int) -> [JobStep] {
        steps.map { step in
            let seconds: Int = max(0, min(step.timeoutSeconds, budget))
            guard seconds != step.timeoutSeconds else { return step }
            // 逐欄複製、只換逾時：漏掉任何一欄都會靜默丟失資訊，而丟失的那一刻不會有人發現。
            return .init(
                name: step.name,
                script: step.script,
                allowFailure: step.allowFailure,
                timeoutSeconds: seconds,
                runCondition: step.runCondition,
                unrecognisedRunCondition: step.unrecognisedRunCondition
            )
        }
    }

    /// 掃出 payload 裡所有本片不消化的能力宣告，依「先擋路的、後可降級的」排列。
    private static func unsupportedFeatures(in job: JobResponse) -> [UnsupportedJobFeature] {
        var features: [UnsupportedJobFeature] = []
        // 讀不懂的欄位排最前面：底下每一條判定都建立在「payload 形狀如預期」之上，
        // 這個前提一旦不成立，其餘結論全都不可信。
        features.append(contentsOf: job.unreadableFields.map(UnsupportedJobFeature.unreadablePayloadField(name:)))
        // 判準是「CI 檔有沒有要求 image」而非「名字寫了沒」——送了 image 物件卻沒帶名字，
        // 要求仍然成立，當沒看到就會讓一個要容器的 job 在裸環境跑完回綠。
        if let imageName: String = job.imageName {
            features.append(.image(name: imageName))
        }
        if job.serviceCount > 0 {
            features.append(.services(count: job.serviceCount))
        }
        if job.artifactCount > 0 {
            features.append(.artifacts(count: job.artifactCount))
        }
        // 判準是「這個上游真的存了產物」而不是「有沒有上游」——站台送的是全部上游。
        let carrying: [String] = job.dependencies.filter(\.carriesArtifacts).map(\.name)
        if !carrying.isEmpty {
            features.append(.dependencyArtifacts(jobNames: carrying))
        }
        if job.cacheCount > 0 {
            features.append(.cache(count: job.cacheCount))
        }
        return features
    }
}
