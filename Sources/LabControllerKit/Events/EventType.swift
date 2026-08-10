//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 事件型別識別字。
///
/// 之所以不是 enum：本模組是通用引擎，實際有哪些事件型別隨部署端的規章而異——把型別集合
/// 編進程式碼，等於每加一個型別就得改庫、發版、重佈署。型別集合改由組態注入，
/// 見 ``EventTypeRegistry``。
public struct EventType: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {

    /// 識別字原值；與組態表、持久層、事件紀錄中出現的字串同一個。
    public let rawValue: String

    /// 以識別字建立；空字串、帶前後空白者、含隱形字元者一律拒絕。
    ///
    /// 擋的都是**肉眼看不出來的差異**：組態是手寫的，`"mr_outdated"` 與 `"mr_outdated "`、
    /// 或尾巴多一個 soft hyphen、中間夾一個 Hangul filler 的版本，在編輯器裡長得一模一樣，
    /// 但會是兩個彼此無關的型別——去重、節流與統計各自為政，且沒有任何一處會報錯。
    /// 逐純量的判準：擋掉控制與格式字元（Cc／Cf）、default-ignorable 純量、半形空格以外的
    /// 所有空白，以及點字空方。**這不是「兩個識別字不可能長得一樣」的證明**——同形異碼
    /// （拉丁 `a` 與西里爾 `а`）、連續兩個半形空格依然是看起來相同的兩個型別，那條線靠組態
    /// 審查。另一項代價：variation selector 與 ZWJ 也在 default-ignorable 之列，帶修飾的
    /// emoji 序列會被拒。
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else {
            return nil
        }
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        guard rawValue.unicodeScalars.allSatisfy({ Self.isVisible($0) }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// 自單值容器解碼；識別字不合法即視為組態錯誤直接失敗，不靜默回落。
    public init(from decoder: any Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let raw: String = try container.decode(String.self)
        guard let decoded: EventType = .init(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "事件型別識別字不合法：\(Self.diagnostic(for: raw))"
            )
        }
        self = decoded
    }

    /// 編碼為單一字串。
    public func encode(to encoder: any Encoder) throws {
        var container: SingleValueEncodingContainer = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// 日誌與錯誤訊息中的呈現形式，即識別字本身。
    public var description: String {
        rawValue
    }

    /// 點字空方；渲染成空白，但它既不屬空白類也不是 default-ignorable，只能單獨列出。
    private static let brailleBlank: Unicode.Scalar = "\u{2800}"

    /// 此純量在畫面上是否留得下可辨識的形體。
    ///
    /// 擋四類：控制與格式字元（Cc／Cf）、default-ignorable 純量（Hangul filler、variation
    /// selector 一族）、半形空格以外的所有空白（NBSP、全形空格等），以及點字空方。
    ///
    /// ⚠ 這是把已知的隱形字元擋掉，**不是**「兩個識別字不可能長得一樣」的證明——同形異碼
    /// （拉丁 `a` 與西里爾 `а`）、連續兩個半形空格，依然會是看起來相同的兩個型別。本模組
    /// 不代為判斷字形相似度，那條線要靠組態審查。
    ///
    /// ⚠ 代價：variation selector 與 ZWJ 也在 default-ignorable 之列，`"warn⚠️"`、
    /// `"family👨‍👩‍👦"` 這類帶修飾的 emoji 序列會被拒。識別字限單純可見文字；要用 emoji
    /// 請用不帶修飾的碼位。
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar) {
            return false
        }
        if scalar.properties.isDefaultIgnorableCodePoint {
            return false
        }
        if scalar.properties.isWhitespace, scalar != " " {
            return false
        }
        return scalar != brailleBlank
    }

    /// 說明識別字哪裡不合法。
    ///
    /// **不能只把原字串內插進訊息**：被擋的字元定義上就是看不見的，原樣印出來會與正確的
    /// 識別字逐像素相同，讀訊息的人根本看不出差在哪。這裡改成標出違規位置與碼位。
    private static func diagnostic(for raw: String) -> String {
        guard !raw.isEmpty else {
            return "不得為空字串"
        }
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "不得帶前後空白：\(rendered(raw))"
        }
        let offenders: [String] = raw.unicodeScalars.enumerated()
            .filter { !isVisible($0.element) }
            .map { "第 \($0.offset + 1) 個字元 \(codePoint($0.element))" }
        return "含隱形字元（\(offenders.joined(separator: "、"))）：\(rendered(raw))"
    }

    /// 把看不見的純量換成碼位標記，讓訊息本身顯示得出差異；可見字元原樣保留。
    private static func rendered(_ raw: String) -> String {
        var rendered: String = ""
        for scalar: Unicode.Scalar in raw.unicodeScalars {
            if isVisible(scalar), scalar != " " {
                rendered.unicodeScalars.append(scalar)
            } else {
                rendered += "<\(codePoint(scalar))>"
            }
        }
        return rendered
    }

    /// 純量的 `U+XXXX` 表示；不足四位補零。
    private static func codePoint(_ scalar: Unicode.Scalar) -> String {
        let hex: String = .init(scalar.value, radix: 16, uppercase: true)
        let padding: String = .init(repeating: "0", count: max(0, 4 - hex.count))
        return "U+\(padding)\(hex)"
    }
}
