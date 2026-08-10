//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 逐字串取用的動態 coding key；供組態型別列出「檔案裡實際出現的欄位」。
///
/// 具名 `CodingKeys` 的 `allKeys` **會先濾掉未知鍵**，所以看不到打錯字的欄位；要抓
/// `secnods` 這種拼錯，只能用動態鍵把整個物件的鍵重讀一次。
struct ConfigurationCodingKey: CodingKey {

    /// 欄位名。
    let stringValue: String

    /// 組態欄位一律具名，數字索引不適用。
    var intValue: Int? {
        nil
    }

    /// 以欄位名建立；動態鍵一律成功。
    init(stringValue: String) {
        self.stringValue = stringValue
    }

    /// 數字索引不適用，一律建不起來。
    init?(intValue: Int) {
        nil
    }

    /// 確認這層組態物件沒有出現 `known` 以外的欄位，有就拋 `DecodingError`。
    ///
    /// 組態是手寫的，多出來的欄位幾乎都是打錯字——靜默忽略的結果是那一項設定完全沒生效，
    /// 而且沒有任何一處會提。站台回應走的是另一套（未知欄位屬正常演進、刻意忽略），兩者
    /// 的取捨方向相反，別互相套用。
    ///
    /// ⚠ 擋不到**同名欄位重複出現**（`{"seconds": 300, "seconds": 900}`）：解碼層看到的
    /// 已經是去重後的結果，後出現的那個在更早的階段就消失了。
    ///
    /// ⚠ 實作上會對同一個 `Decoder` 再要一次 keyed container；標準庫的 JSON 與 plist
    /// decoder 都允許，但這不是 `Decoder` 協定明文保證的行為。
    static func assertNoUnknownKeys(in decoder: any Decoder, known: Set<String>) throws {
        let container: KeyedDecodingContainer<ConfigurationCodingKey> = try decoder.container(
            keyedBy: ConfigurationCodingKey.self
        )
        let unknown: [String] = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "組態出現未知欄位：\(unknown.joined(separator: "、"))"
                )
            )
        }
    }
}
