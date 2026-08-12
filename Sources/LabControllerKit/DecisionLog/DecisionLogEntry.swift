//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 決策日誌的一行：不是決策紀錄（``DecisionRecord``）就是 job 紀錄（``JobRecord``）。
///
/// 日誌是 NDJSON——每則紀錄一行 JSON、行與行以換行分隔。這個型別負責「一則紀錄 ⇄ 一行
/// 文字」的轉換，本身零 I/O：``jsonLine()`` 產出**不含尾隨換行**的單行字串，實際寫檔（把多行
/// 以換行接起、append 落檔）由呼叫端做——純值層不碰檔案系統，和 ``EventKey``／``DetectedEvent``
/// 同一取態。
///
/// **為什麼保證得了「單行」**：JSONEncoder 在非 pretty 模式下，字串值裡的控制字元（含換行）
/// 一律轉義成 `\n` 之類的兩字元序列，物件本身也不含縫隙——所以不管欄位內容多敵意（換行、
/// 組合字元、`|`），編出來的 JSON 都不會冒出真正的換行把一行拆成兩行。這是 NDJSON 逐行可切
/// 的前提，有敵意字串測試釘住（見測試）。
///
/// **辨別哪一種紀錄靠鍵名本身**：一行的頂層恰有一個鍵，`decision` 或 `job`，不另設判別欄。
/// 解碼時鍵在、但值壞掉會照實丟錯（`decodeIfPresent` 只對「鍵缺席／null」回 `nil`，不吞解碼
/// 失敗）——壞行 loud fail、不靜靜落成空紀錄。
public enum DecisionLogEntry: Sendable, Equatable {

    /// 一則決策紀錄。
    case decision(DecisionRecord)

    /// 一則 job 紀錄。
    case job(JobRecord)

    /// 日誌格式版本；編碼規則（欄位、raw value、日期格式）一改就跟著改，落在持久層的舊行
    /// 才追得出是哪一代。各紀錄型別的 `schemaVersion` 欄預設取這裡。
    public static let schemaVersion: String = "v1"

    /// 編碼／解碼失敗的具名原因；不吞錯、不以空值代過。
    public enum CodingFailure: Error, Equatable {

        /// 編碼結果不是合法 UTF-8（理論上不會發生，但不以強制解包假設它不發生）。
        case notUTF8

        /// 讀回的一行既不是決策紀錄也不是 job 紀錄。
        case unknownLineShape
    }

    /// 把這則紀錄編成一行 NDJSON（不含尾隨換行）。
    public func jsonLine() throws -> String {
        let data: Data = try Self.makeEncoder().encode(self)
        guard let line: String = .init(data: data, encoding: .utf8) else { throw CodingFailure.notUTF8 }
        return line
    }

    /// 自一行 NDJSON 讀回一則紀錄。
    public init(jsonLine: String) throws {
        guard let data: Data = jsonLine.data(using: .utf8) else { throw CodingFailure.notUTF8 }
        self = try Self.makeDecoder().decode(Self.self, from: data)
    }

    /// 本型別專用的編碼器；每次產生新實例——JSONEncoder 在 Swift 6 並行模型下不是 Sendable，
    /// 不宜做成共享 static，且日誌不是熱路徑，重建成本可忽略。
    ///
    /// `sortedKeys` 讓同一則紀錄每次編出逐 byte 相同的字串（測試可釘、diff 乾淨）；
    /// `iso8601` 讓時刻是人可讀的字串——⚠ 它**不含小數秒**，同一秒內的兩則紀錄時刻會相同，
    /// 先後仍靠 NDJSON 的行序保留，決策輪為秒級、這個精度足夠。
    private static func makeEncoder() -> JSONEncoder {
        let encoder: JSONEncoder = .init()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// 對應 ``makeEncoder()`` 的解碼器；日期同以 `iso8601` 讀回。
    private static func makeDecoder() -> JSONDecoder {
        let decoder: JSONDecoder = .init()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension DecisionLogEntry: Codable {

    /// 頂層鍵即判別：一行恰有一個鍵，鍵名決定是哪一種紀錄。
    private enum CodingKeys: String, CodingKey {

        /// 決策紀錄。
        case decision

        /// job 紀錄。
        case job
    }

    /// 依 case 把紀錄本體編到對應的頂層鍵下（`decision` 或 `job`）；鍵名即判別，不另設判別欄。
    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .decision(record):
            try container.encode(record, forKey: .decision)
        case let .job(record):
            try container.encode(record, forKey: .job)
        }
    }

    /// 自一行的頂層鍵辨識並解出紀錄；鍵的存在情形與本體合法性都照實把關（見內文註解）。
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        // 頂層必須恰有一個可辨識的鍵：零個（既不是 decision 也不是 job）或兩個都在（外部產生
        // 或被竄改的行）一律 loud fail、不靜靜取其一。認得的鍵才會進 `allKeys`，所以 `{"other":…}`
        // 也落在零個這一支。
        guard container.allKeys.count == 1, let key: CodingKeys = container.allKeys.first else {
            throw CodingFailure.unknownLineShape
        }
        // 鍵在、值壞（缺必填欄、型別不符）由 `decode` 照實丟解碼錯——不被壓成空值吞掉。
        // ⚠ 這裡刻意不驗 `schemaVersion`：版本是寫給日後讀日誌的人追代次用的佐證，不是解碼閘；
        // 驗它會讓舊版 binary 讀不過新版行、失去「跳過不認得的行、繼續讀」的能力。
        switch key {
        case .decision:
            self = .decision(try container.decode(DecisionRecord.self, forKey: .decision))
        case .job:
            self = .job(try container.decode(JobRecord.self, forKey: .job))
        }
    }
}
