//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 步驟的執行條件；對應協議 `steps[].when`。
///
/// 站台端一律顯式帶值（16.2 `lib/gitlab/ci/build/step.rb`：`script` 與 `release` 給
/// `on_success`、`after_script` 給 `always`），故缺席回落屬防禦、非常態路徑。
public enum JobStepWhen: String, Sendable, Equatable {

    /// 先前步驟全數成功時才跑。
    case onSuccess = "on_success"

    /// 先前步驟已有失敗時才跑。
    case onFailure = "on_failure"

    /// 不論先前結果都要跑；`after_script` 屬此類。
    case always

    /// 在「目前是否已有步驟失敗」的前提下，這個步驟該不該跑。
    ///
    /// 判斷刻意留在協議層：`after_script` 之所以能在失敗後仍收拾現場，靠的就是這個
    /// 欄位；把它折進執行器的控制流會讓「為什麼這步驟還在跑」變成讀不出來的行為。
    public func shouldRun(afterFailure hasFailed: Bool) -> Bool {
        switch self {
        case .onSuccess:
            return !hasFailed
        case .onFailure:
            return hasFailed
        case .always:
            return true
        }
    }
}
