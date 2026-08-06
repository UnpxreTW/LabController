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

private final class EventTypeTests {

    /// 一般識別字建得起來、原值原樣保留。
    @Test
    func `accepts a plain identifier`() throws {
        let type: EventType = try #require(.init(rawValue: "merge_request_outdated"))
        #expect(type.rawValue == "merge_request_outdated")
        #expect(type.description == "merge_request_outdated")
    }

    /// 空字串不是合法識別字。
    @Test
    func `rejects an empty identifier`() {
        #expect(EventType(rawValue: "") == nil)
    }

    /// 帶前後空白者一律拒絕：組態手寫時肉眼分不出來，放行會長出兩個看似同名的型別。
    @Test
    func `rejects identifiers padded with whitespace`() {
        #expect(EventType(rawValue: " padded") == nil)
        #expect(EventType(rawValue: "padded ") == nil)
        #expect(EventType(rawValue: "padded\n") == nil)
        #expect(EventType(rawValue: "   ") == nil)
    }

    /// 內部空白（真的空白字元）照收；識別字長什麼樣由組態決定。
    @Test
    func `accepts inner whitespace`() throws {
        let type: EventType = try #require(.init(rawValue: "two words"))
        #expect(type.rawValue == "two words")
    }

    /// 隱形的控制／格式字元一律拒絕——它們在編輯器裡完全看不出來，放行就會長出兩個
    /// 肉眼相同卻互不相等的型別。
    @Test
    func `rejects invisible control and format characters`() {
        let invisibles: [String] = [
            "deploy_blocked\u{00AD}",   // soft hyphen
            "\u{FEFF}deploy_blocked",   // byte order mark
            "deploy\u{200D}_blocked",   // zero width joiner
            "deploy_blocked\u{2060}",   // word joiner
            "deploy_blocked\u{180E}",   // mongolian vowel separator
            "deploy\u{000A}blocked",    // 內嵌換行
            "deploy_blocked\u{3164}",   // hangul filler
            "deploy_blocked\u{FFA0}",   // halfwidth hangul filler
            "deploy_blocked\u{115F}",   // hangul choseong filler
            "deploy_blocked\u{FE0F}",   // variation selector-16
            "deploy_blocked\u{E0100}",  // variation selector-17
            "deploy_blocked\u{2800}",   // braille pattern blank
            "deploy\u{00A0}blocked",    // 內嵌 no-break space
            "deploy\u{3000}blocked"     // 內嵌全形空格
        ]
        for invisible: String in invisibles {
            #expect(EventType(rawValue: invisible) == nil, "應拒絕：\(Array(invisible.unicodeScalars))")
        }
    }

    /// 編碼為單一字串、解回同值。
    @Test
    func `round trips through json as a bare string`() throws {
        let type: EventType = try #require(.init(rawValue: "lint_scan_pending"))
        let data: Data = try JSONEncoder().encode(type)
        let encoded: String = try #require(String(bytes: data, encoding: .utf8))
        #expect(encoded == "\"lint_scan_pending\"")
        #expect(try JSONDecoder().decode(EventType.self, from: data) == type)
    }

    /// 解碼不合法識別字＝組態錯誤，直接失敗而非靜默回落。
    @Test
    func `decoding rejects an invalid identifier`() {
        let data: Data = .init("\" padded \"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventType.self, from: data)
        }
    }

    /// 失敗訊息必須指出看不見的那個字元在第幾位、是哪個碼位——把原字串原樣印出來沒有用，
    /// 它與正確的識別字看起來一模一樣。
    @Test
    func `the decoding error names the invisible scalar`() throws {
        let data: Data = .init("\"mr_outdated\u{00AD}\"".utf8)
        do {
            _ = try JSONDecoder().decode(EventType.self, from: data)
            Issue.record("應該解不出來")
        } catch let DecodingError.dataCorrupted(context) {
            #expect(context.debugDescription.contains("U+00AD"))
            #expect(context.debugDescription.contains("第 12 個字元"))
        }
    }
}
