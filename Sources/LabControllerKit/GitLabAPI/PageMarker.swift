//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 自分頁回應標頭解出的翻頁位置。
///
/// ## 為什麼不看 `X-Total-Pages`
///
/// 集合筆數超過上限時站台會切換成不計數的分頁，`OffsetHeaderBuilder#execute` 在該情況**整組略過**
/// `X-Total`／`X-Total-Pages` 兩個標頭。也就是說「總頁數」恰恰在集合最大、最需要翻頁的時候消失。
/// 以它推導終止條件的迴圈在小專案上會通過所有測試、在大專案上讀完第一頁就收工。
///
/// `X-Next-Page` 則永遠會發（沒有下一頁時值為空字串，因為站台送的是 `next_page.to_s`），
/// 是唯一在兩種模式下都成立的終止依據。
///
/// ## 為什麼不用「這頁比要求的少」當終止條件
///
/// 站台會把超過上限的 `per_page` **無聲收成上限值**（Kaminari `max_per_page`）。要求 500 筆、
/// 拿回 100 筆，以「不滿一頁即最後一頁」判斷就會在第一頁停手，而站台其實還有幾十頁。
/// 本型別因此完全不看筆數。
public struct PageMarker: Sendable, Equatable {

    /// 站台回報這是第幾頁（`X-Page`）。
    public let page: Int

    /// 站台實際採用的每頁筆數（`X-Per-Page`）；標頭缺席時為 `nil`。
    ///
    /// 保留它的用途是讓呼叫端看得到「站台把 `per_page` 收小了」——這不影響正確性，但會讓翻頁預算
    /// 涵蓋的實際筆數比預期少，是排查「怎麼一直讀不完」時的第一個要看的數字。
    public let perPage: Int?

    /// 下一頁頁碼；`nil` 代表這是最後一頁。
    public let nextPage: Int?

    /// 從回應標頭解析，並就地驗證翻頁位置的一致性。
    ///
    /// - Parameters:
    ///   - response: 站台回應。
    ///   - requestedPage: 本次請求的頁碼。
    /// - Throws: `GitLabAPIError.malformedPagination`，於下列任一情況：
    ///   - 缺 `X-Page` 或其值非整數——分頁標頭被中間層剝掉時，靜默當成單頁會讓輪詢**永遠只讀第一頁**。
    ///   - `X-Page` 與 `requestedPage` 不符——快取或代理回了別頁。照收會把那頁的內容誤記成本頁，
    ///     且下一頁的頁碼是從錯的位置往下推。
    ///   - 下一頁頁碼不大於本頁——迴圈會原地打轉；這是唯一不需要外部計時器就能擋下的無限迴圈形狀。
    public init(response: HTTPResponse, requestedPage: Int) throws {
        guard let rawPage: String = response.headerValue("X-Page"), let page: Int = .init(rawPage) else {
            throw GitLabAPIError.malformedPagination("X-Page 缺席或非整數")
        }
        guard page == requestedPage else {
            throw GitLabAPIError.malformedPagination("要求第 \(requestedPage) 頁、站台回報第 \(page) 頁")
        }
        // 空字串＝沒有下一頁（站台送的是 next_page.to_s，nil 會變成空字串而非省略標頭）。
        let rawNext: String? = response.headerValue("X-Next-Page").flatMap { $0.isEmpty ? nil : $0 }
        let nextPage: Int? = try rawNext.map { raw in
            guard let value: Int = .init(raw) else {
                throw GitLabAPIError.malformedPagination("X-Next-Page 非整數：\(raw)")
            }
            guard value > page else {
                throw GitLabAPIError.malformedPagination("下一頁 \(value) 未大於本頁 \(page)")
            }
            return value
        }
        self.page = page
        self.perPage = response.headerValue("X-Per-Page").flatMap(Int.init)
        self.nextPage = nextPage
    }
}
