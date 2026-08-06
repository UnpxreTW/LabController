//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 「上次讀到哪裡」的輪詢水位；送給站台時成為 `updated_after` 查詢參數。
///
/// ## 為什麼水位只到整秒
///
/// 水位一律向下取整到整秒（`flooredToSecond`），而站台的 `updated_after` 是**閉區間**
/// （`v16.2.0-ee` 的 `UpdatedAtFilterable` 以 `updated_at >= date` 實作）。兩者相加的效果是
/// **水位那一整秒必定會被重讀一次**。
///
/// 這是刻意付出的成本，換掉三個各自都會靜默漏事件的風險：
///
/// 1. **平手**：站台對 `order_by=updated_at` 只下 `reorder(updated_at)`、**沒有第二排序鍵**
///    （`Sortable` 的 `order_updated_asc`），同一秒內的先後在資料庫層並不固定。若水位精確到
///    毫秒並停在平手群中間，下一輪換個順序就會有成員落在水位之前、永遠讀不到。整秒水位讓
///    整個平手群一起重讀。
/// 2. **精度往返**：水位要經過 ISO-8601 字串、儲存層與站台的時間欄位好幾手。任何一手把小數位
///    四捨五入**進位**，被跳過的那一段就再也不會被查詢涵蓋。向下取整讓誤差只會往「重讀」倒。
/// 3. **重讀無害**：重複的事件由去重層吸收；漏掉的事件沒有任何一層會發現。
///
/// ## 水位只前進、不後退
///
/// `advanced(to:noLaterThan:)` 取新舊值的較大者。站台時鐘往回跳（NTP 校正、機器搬遷）時
/// 水位會停住不動而不是倒退重放整段歷史；停住的代價是重讀，倒退的代價是把已處理的事件整批重發。
public struct UpdatedAfterCursor: Sendable, Equatable, Hashable, Codable {

    /// 已確認讀完的水位；`nil` 代表尚未輪詢過、首輪不帶 `updated_after`（讀全集）。
    ///
    /// 恆為整秒——建構時即取整，故此不變式由型別保證、不靠呼叫端自律。
    public let watermark: Date?

    /// 以水位建立；傳入值會先向下取整到整秒。
    public init(watermark: Date? = nil) {
        self.watermark = watermark.map(Self.flooredToSecond)
    }

    /// 送給站台的 `updated_after` 參數值；`nil` 時整個參數省略、代表讀全集。
    ///
    /// 固定以 UTC、無小數秒的 ISO-8601 呈現（`2026-08-06T09:48:00Z`）。不帶小數秒是上面
    /// 「整秒水位」的延伸——形狀上就無法表達比一秒更細的位置，也就無從被四捨五入弄丟。
    public var queryValue: String? {
        watermark.map { date in
            date.formatted(
                Date.ISO8601FormatStyle(
                    dateSeparator: .dash,
                    dateTimeSeparator: .standard,
                    timeSeparator: .colon,
                    timeZoneSeparator: .omitted,
                    includingFractionalSeconds: false,
                    timeZone: .gmt
                )
            )
        }
    }

    /// 依本輪觀察推進水位。
    ///
    /// - Parameters:
    ///   - observed: 本輪確認「其之前已無遺漏」的最大 `updated_at`；`nil` 表示本輪沒有可推進的
    ///     依據，水位原地不動。**哪一筆算數由呼叫端決定**——翻頁期間集合可能被改動，
    ///     判準寫在 `ProjectResourcePoller`。
    ///   - walkStartedAt: 本輪開始時的**站台**時鐘。水位不會越過這個時刻。
    /// - Returns: 推進後的水位；不會比原水位早。
    ///
    /// `walkStartedAt` 這道上限治的是「查詢快照」與「交易提交」的順序差：資料庫可能存在一筆
    /// `updated_at` 已經寫成某個較早時刻、但交易在我們的查詢跑完之後才提交的資料。它對本輪查詢
    /// 不可見，卻帶著本輪水位之前的時間戳。水位若推到「現在」，這筆資料就永遠落在查詢範圍之外；
    /// 壓在本輪起始時刻則保證它下一輪還在範圍內。
    ///
    /// 同理，本輪沒讀到任何資料時（`observed` 為 `nil`）水位**不推進**：空結果只證明查詢當下沒看到
    /// 東西，不證明那段時間真的沒有東西被改過。
    public func advanced(to observed: Date?, noLaterThan walkStartedAt: Date) -> Self {
        guard let observed else {
            return self
        }
        let floored: Date = Self.flooredToSecond(min(observed, walkStartedAt))
        guard let watermark else {
            return .init(watermark: floored)
        }
        return floored > watermark ? .init(watermark: floored) : self
    }

    /// 向下取整到整秒（往更早的方向，含 1970 之前的負值）。
    ///
    /// 用 `.down`（趨向負無限）而非 `.towardZero`：後者對 1970 前的時刻會往「較晚」取整，
    /// 剛好是會弄丟資料的方向。
    static func flooredToSecond(_ date: Date) -> Date {
        .init(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
