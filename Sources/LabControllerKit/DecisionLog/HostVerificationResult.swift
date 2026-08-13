//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// host 拿 guest 回報的結果向站台終態二次核對後的判定。
///
/// 「guest 依 done_when 自評、host 依站台終態終審」是整個系統回答「容器內執行者怎麼知道算
/// 完成」的那一層——這個型別記的是終審那一邊。它與 ``JobOutcome`` 刻意分開：guest 自評與
/// 站台實況不一致（自評完成、站台沒動）正是最需要在事後查得出來的一類事故。
public enum HostVerificationResult: String, Sendable, Equatable, Codable, CaseIterable {

    /// 站台終態與 guest 自評一致（如 rebase job：MR `diverged_commits_count == 0` 且 sha 已變）。
    case confirmed

    /// 站台終態與 guest 自評不符——guest 說完成、站台實況並非如此。
    case mismatch

    /// 本輪未能取得站台終態（API 不可達等），核對未完成、不等於通過。
    case unavailable
}
