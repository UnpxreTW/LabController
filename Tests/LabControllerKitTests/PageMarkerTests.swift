//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import LabControllerKit
import Testing

private final class PageMarkerTests {

    /// 站台在最後一頁送的是**空字串**（`next_page.to_s`），不是省略標頭；空字串必須解成「沒有下一頁」。
    @Test
    func `empty next page header means last page`() throws {
        let response: HTTPResponse = .init(
            statusCode: 200,
            headers: ["X-Page": "3", "X-Per-Page": "100", "X-Next-Page": ""]
        )
        let marker: PageMarker = try .init(response: response, requestedPage: 3)
        #expect(marker.nextPage == nil)
        #expect(marker.page == 3)
    }

    /// 標頭整個缺席代表被中途拿掉了：站台一定會發這個標頭，最後一頁發的是空字串而非省略。
    ///
    /// 靜默當成最後一頁，會讓輪詢每輪只讀一頁、而且回報一切正常——吞吐量無聲崩塌，
    /// 正是本模組明說不接受的形狀。
    @Test
    func `absent next page header is rejected`() {
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: .init(statusCode: 200, headers: ["X-Page": "1"]), requestedPage: 1)
        }
    }

    /// 有下一頁時解出頁碼。
    @Test
    func `next page header yields the following page`() throws {
        let response: HTTPResponse = .init(statusCode: 200, headers: ["X-Page": "1", "X-Next-Page": "2"])
        #expect(try PageMarker(response: response, requestedPage: 1).nextPage == 2)
    }

    /// HTTP 標頭名稱大小寫不敏感，各層轉手後大小寫並不保證。
    @Test
    func `header lookup ignores case`() throws {
        let response: HTTPResponse = .init(statusCode: 200, headers: ["x-page": "1", "x-next-page": "2"])
        #expect(try PageMarker(response: response, requestedPage: 1).nextPage == 2)
    }

    /// 下一頁不大於本頁＝迴圈原地打轉；必須擋下，這是不靠外部計時器就能偵測到的無限迴圈形狀。
    @Test
    func `next page not greater than current page is rejected`() {
        let response: HTTPResponse = .init(statusCode: 200, headers: ["X-Page": "2", "X-Next-Page": "2"])
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: response, requestedPage: 2)
        }
    }

    /// 下一頁往回指同樣擋下。
    @Test
    func `next page pointing backwards is rejected`() {
        let response: HTTPResponse = .init(statusCode: 200, headers: ["X-Page": "5", "X-Next-Page": "1"])
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: response, requestedPage: 5)
        }
    }

    /// 下一頁往前跳號也擋下：那一頁不會被請求，內容整頁不見，而呼叫端收到的是一切正常。
    @Test
    func `next page skipping ahead is rejected`() {
        let response: HTTPResponse = .init(statusCode: 200, headers: ["X-Page": "1", "X-Next-Page": "3"])
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: response, requestedPage: 1)
        }
    }

    /// 缺 `X-Page` 不可靜默當單頁：那會讓輪詢永遠只讀第一頁而毫無徵兆。
    @Test
    func `missing current page header is rejected`() {
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: .init(statusCode: 200, headers: ["X-Next-Page": "2"]), requestedPage: 1)
        }
    }

    /// `X-Page` 非整數同樣視為分頁標頭壞掉。
    @Test
    func `non numeric current page header is rejected`() {
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: .init(statusCode: 200, headers: ["X-Page": "first"]), requestedPage: 1)
        }
    }

    /// `X-Next-Page` 非空但非整數，也不可當成「沒有下一頁」帶過。
    @Test
    func `non numeric next page header is rejected`() {
        let response: HTTPResponse = .init(statusCode: 200, headers: ["X-Page": "1", "X-Next-Page": "next"])
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: response, requestedPage: 1)
        }
    }

    /// 回報的頁碼與要求的不符＝拿到了別頁（快取或代理）；照收會把內容記在錯的位置上。
    @Test
    func `page mismatch against the requested page is rejected`() {
        let response: HTTPResponse = .init(statusCode: 200, headers: ["X-Page": "1", "X-Next-Page": "2"])
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: response, requestedPage: 4)
        }
    }


    /// 頁碼必須落在能安全加一的範圍內：`Int.max` 會讓「下一頁應為本頁加一」的檢查在算術層當掉，
    /// 而頁碼是站台與呼叫端各給一半的值，不該由此讓行程結束。
    @Test
    func `an unusable page number is rejected before arithmetic`() {
        let response: HTTPResponse = .init(
            statusCode: 200,
            headers: ["X-Page": "9223372036854775807", "X-Next-Page": "1"]
        )
        #expect(throws: GitLabAPIError.self) {
            try PageMarker(response: response, requestedPage: Int.max)
        }
    }
}
