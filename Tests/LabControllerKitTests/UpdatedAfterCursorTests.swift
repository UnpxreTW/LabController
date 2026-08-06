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

private final class UpdatedAfterCursorTests {

    /// 2026-08-06T09:00:00Z，作為以下各例的參考時刻。
    private static let reference: TimeInterval = 1_786_006_800

    /// 建構時即向下取整到整秒——「水位恆為整秒」是型別保證，不是呼叫端要記得做的事。
    @Test
    func `watermark is floored to whole seconds on construction`() {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: Self.reference + 0.987))
        #expect(cursor.watermark == Date(timeIntervalSince1970: Self.reference))
    }

    /// 1970 之前的時刻同樣往「更早」取整。趨向零取整會讓這段往晚跑，剛好是會漏資料的方向。
    @Test
    func `flooring moves earlier for instants before the epoch`() {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: -0.5))
        #expect(cursor.watermark == Date(timeIntervalSince1970: -1))
    }

    /// 查詢值固定為 UTC、無小數秒的 ISO-8601；形狀上就無法表達比一秒更細的位置。
    @Test
    func `query value renders as whole second utc iso8601`() {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: Self.reference + 0.987))
        #expect(cursor.queryValue == "2026-08-06T09:00:00Z")
    }

    /// 尚未輪詢過時整個參數省略，代表讀全集。
    @Test
    func `unset cursor omits the query parameter`() {
        #expect(UpdatedAfterCursor().queryValue == nil)
    }

    /// 本輪沒有觀察值時水位原地不動：空結果只證明查詢當下沒看到東西，不證明那段時間沒有東西被改過。
    @Test
    func `absent observation leaves the watermark untouched`() {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: Self.reference))
        let advanced: UpdatedAfterCursor = cursor.advanced(
            to: nil,
            noLaterThan: .init(timeIntervalSince1970: Self.reference + 3600)
        )
        #expect(advanced == cursor)
    }

    /// 觀察值晚於本輪起始時刻時，水位壓在起始時刻——晚於它的資料下一輪還要再讀一次。
    @Test
    func `watermark is capped at the walk start`() {
        let start: Date = .init(timeIntervalSince1970: Self.reference)
        let advanced: UpdatedAfterCursor = UpdatedAfterCursor().advanced(
            to: .init(timeIntervalSince1970: Self.reference + 3600),
            noLaterThan: start
        )
        #expect(advanced.watermark == start)
    }

    /// 觀察值早於現有水位時水位不倒退（重複的舊資料不該把已推進的進度拉回去）。
    @Test
    func `watermark never moves backwards on an older observation`() {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: Self.reference))
        let advanced: UpdatedAfterCursor = cursor.advanced(
            to: .init(timeIntervalSince1970: Self.reference - 3600),
            noLaterThan: .init(timeIntervalSince1970: Self.reference + 3600)
        )
        #expect(advanced == cursor)
    }

    /// 站台時鐘往回跳時水位停住。停住的代價是重讀，倒退的代價是把已處理的事件整批重發。
    @Test
    func `backwards server clock freezes the watermark`() {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: Self.reference))
        let advanced: UpdatedAfterCursor = cursor.advanced(
            to: .init(timeIntervalSince1970: Self.reference + 3600),
            noLaterThan: .init(timeIntervalSince1970: Self.reference - 3600)
        )
        #expect(advanced == cursor)
    }

    /// 同一秒內的更晚觀察值不構成推進——避免在平手群中間停住（站台對 `updated_at` 沒有第二排序鍵）。
    @Test
    func `an observation later within the same second does not advance`() {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: Self.reference))
        let advanced: UpdatedAfterCursor = cursor.advanced(
            to: .init(timeIntervalSince1970: Self.reference + 0.9),
            noLaterThan: .init(timeIntervalSince1970: Self.reference + 3600)
        )
        #expect(advanced == cursor)
    }

    /// 跨過整秒邊界才推進，且推進後仍是整秒。
    @Test
    func `crossing a second boundary advances to that whole second`() {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: Self.reference))
        let advanced: UpdatedAfterCursor = cursor.advanced(
            to: .init(timeIntervalSince1970: Self.reference + 1.4),
            noLaterThan: .init(timeIntervalSince1970: Self.reference + 3600)
        )
        #expect(advanced.watermark == Date(timeIntervalSince1970: Self.reference + 1))
    }

    /// 游標要能存進儲存層再讀回來，往返後必須完全相同。
    @Test
    func `cursor round trips through json`() throws {
        let cursor: UpdatedAfterCursor = .init(watermark: .init(timeIntervalSince1970: Self.reference))
        let data: Data = try JSONEncoder().encode(cursor)
        #expect(try JSONDecoder().decode(UpdatedAfterCursor.self, from: data) == cursor)
    }
}
