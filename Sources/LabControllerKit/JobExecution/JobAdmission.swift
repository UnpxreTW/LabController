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

        /// 以缺口清單建立。
        public init(features: [UnsupportedJobFeature]) {
            self.features = features
        }

        /// 回報給站台的失敗分類。
        ///
        /// 固定為「程式錯、不重試」：缺的是本 executor 的能力，重跑幾次結果都一樣。
        /// 標成可重試只會讓同一個 job 白佔執行格好幾輪，然後以同樣的理由再失敗一次。
        public var failureReason: JobFailureReason {
            .scriptFailure
        }

        /// 寫進 trace 的完整說明；逐項列出缺了什麼，一項一行。
        public var traceMessage: String {
            features.map(\.traceMessage).joined(separator: "\n")
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
        let blocking: [UnsupportedJobFeature] = features.filter { $0.severity == .fatal }
        guard blocking.isEmpty else { return .rejected(.init(features: blocking)) }
        return .accepted(
            .init(
                jobIdentifier: job.id,
                git: job.gitInfo,
                steps: job.steps,
                environment: job.variables.filter { !$0.file },
                fileVariables: job.variables.filter(\.file),
                masker: .init(variables: job.variables),
                timeoutSeconds: timeoutPolicy.effectiveSeconds(declaredSeconds: job.runnerInfo?.timeoutSeconds),
                warnings: features.filter { $0.severity == .warning }
            )
        )
    }

    /// 掃出 payload 裡所有本片不消化的能力宣告，依「先擋路的、後可降級的」排列。
    private static func unsupportedFeatures(in job: JobResponse) -> [UnsupportedJobFeature] {
        var features: [UnsupportedJobFeature] = []
        if let imageName: String = job.imageName, !imageName.isEmpty {
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
