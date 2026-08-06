//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 可用 `updated_after` 游標輪詢的專案層集合。
///
/// 收錄門檻是「站台同時支援 `updated_after` 過濾與 `order_by=updated_at` 排序」——兩者缺一，
/// 游標式輪詢就不成立：沒有過濾就每輪讀全集，沒有排序就無從判斷「這個時刻之前都讀完了」。
///
/// 形狀依據為 GitLab `v16.2.0-ee` 原始碼，逐項對照過而非沿用文件：
/// `lib/api/helpers/merge_requests_helpers.rb`、`lib/api/issues.rb`、`lib/api/ci/pipelines.rb`
/// 各自宣告 `updated_after`，`updated_at` 亦在三者的 `order_by` 允許值內。
///
/// 三者的 `updated_after` **都是閉區間**（`>=`）：流水線與議題／合併請求走的是同一個
/// `UpdatedAtFilterable`（`Ci::Pipeline` 明文 include 該 concern，其 scope 以 `gteq` 實作）。
/// 這件事是 `UpdatedAfterCursor` 整秒取整規則的前提，因此逐一確認過、沒有一個集合是例外。
public enum ProjectCollection: String, Sendable, CaseIterable {

    /// 合併請求：`GET /projects/:id/merge_requests`。
    case mergeRequests = "merge_requests"

    /// 議題：`GET /projects/:id/issues`。
    case issues = "issues"

    /// 流水線：`GET /projects/:id/pipelines`。
    ///
    /// ⚠ 此端點對認不得的 `order_by` 值**不報錯、直接回落 `id`**
    /// （`Ci::PipelinesFinder#sort_items`）。回落之後排序與游標無關，翻頁會漏資源而且沒有任何
    /// 徵兆；排序參數因此固定由本模組給、不開放呼叫端覆寫。
    case pipelines = "pipelines"

    /// 接在 `/api/v4/projects/{id}/` 之後的路徑片段。
    public var pathComponent: String { rawValue }
}
