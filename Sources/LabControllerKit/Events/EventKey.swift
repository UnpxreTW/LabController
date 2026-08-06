//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 事件的去重鑰匙：同一件事重複偵測到必得同一把鑰匙，不同的事必得不同的鑰匙。
///
/// **編碼方式，以及為什麼不同的事一定不撞**：把格式版本段與身分各段依序排好，每段正規化成
/// NFC 後逐個 Unicode 純量掃過，遇到 `\` 或 `|` 就在它前面補一個 `\`，再以 `|` 串接。未跳脫
/// 的 `|` 只可能出現在段與段之間，所以段序列可以被無歧義地切回；段序列既然切得回來，兩組
/// **正規化後仍不同**的段就不可能編出同一個字串（正規化後相同者本來就該是同一把鑰匙——
/// `String` 的相等本來就是 canonical equivalence，而持久層逐 byte 比，統一成 NFC 才讓兩邊
/// 的判定一致）。若改成「直接串接、不轉義」，只要有一段的內容含分隔字元
/// （專案路徑、分支名都可能），它就會和另一組完全不同的段撞成同一把鑰匙——而撞鑰匙的後果是
/// 事件被當成重複而靜靜丟掉，沒有任何一處會報錯。
///
/// **首段是格式版本**（``formatVersion``）：編碼規則改動時一併改，落在持久層的舊鑰匙才看得
/// 出是哪一代——否則換代只會表現成「同一批事件莫名重發一輪」，沒有任何地方查得到原因。
/// 鑰匙格式不對外承諾相容性；要與其他來源的既有鑰匙對接，換算由匯入端負責。
///
/// ⚠ 已知限制：NFC 正規化走系統的 Unicode 實作，跨作業系統版本理論上可能對極新指派的純量
/// 給出不同結果。多台機器共用同一份持久層時，這會表現成同一事件落成兩列。
public struct EventKey: Hashable, Sendable, CustomStringConvertible {

    /// 鑰匙字串；持久層與事件紀錄一律存這個值。
    public let rawValue: String

    /// 自事件推導。
    public init(of event: DetectedEvent) {
        var segments: [String] = [Self.formatVersion, event.type.rawValue, event.project]
        segments.append(contentsOf: event.target.keySegments)
        segments.append(contentsOf: event.discriminators)
        self.rawValue = segments.map { Self.escaped($0) }.joined(separator: String(Self.separator))
    }

    /// 自持久層讀回既有鑰匙；原字串即身分，不重新推導、不做任何驗證。
    ///
    /// 這個入口只給「讀回自己先前存下的鑰匙」用。拿別處來的字串餵進來，得到的鑰匙永遠不會
    /// 與推導出的鑰匙相符——去重會恆為失效、事件每輪重發，且沒有任何一處會報錯。
    public init(persisted rawValue: String) {
        self.rawValue = rawValue
    }

    /// 日誌與錯誤訊息中的呈現形式，即鑰匙字串本身。
    public var description: String {
        rawValue
    }

    /// 鑰匙編碼規則的版本；規則一改就跟著改。
    public static let formatVersion: String = "v1"

    /// 段與段之間的分隔純量。
    private static let separator: Unicode.Scalar = "|"

    /// 跳脫純量；出現在段內容裡時自己也要被跳脫。
    private static let escape: Unicode.Scalar = "\\"

    /// 先正規化成 NFC，再逐 Unicode 純量轉義。
    ///
    /// **必須逐純量、不能用 `String` 的 Character 版取代 API**：那些 API 以 grapheme cluster
    /// 為比對單位，落在多純量 grapheme 裡的分隔字元（例如 `|` 後面接一個 combining mark）
    /// 比不到、於是不會被轉義，而串接時 grapheme 邊界又會重算——結果是 `["a", "\u{0301}b"]`
    /// 與 `["a|\u{0301}b"]` 編出同一把鑰匙。
    ///
    /// **先做 NFC 的理由**：`String` 的相等是 canonical equivalence，而持久層（sqlite 的
    /// TEXT）是逐 byte 比。不正規化的話，同一段文字的 NFC 與 NFD 兩種寫法在程式內判定相等、
    /// 落到資料庫卻是兩列——同一件事於是被送出兩次。統一成 NFC 讓兩邊的判定一致。
    private static func escaped(_ segment: String) -> String {
        var escaped: String = ""
        for scalar: Unicode.Scalar in segment.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar == separator || scalar == escape {
                escaped.unicodeScalars.append(escape)
            }
            escaped.unicodeScalars.append(scalar)
        }
        return escaped
    }
}
