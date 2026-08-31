//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 送給 nymph daemon 的一則請求，本側的線上形狀。
///
/// **這是一份鏡像、不是引用**：對面的型別住在另一個專案裡，把它當函式庫引進來會讓本專案的
/// 建置與那一側的版本綁在一起，而這一側真正需要的只有「線上長什麼樣」。鏡像的代價是兩邊要
/// 各自維護同一個形狀，所以形狀本身由測試以逐字的 JSON 釘住（見 `NymphWireFormatTests`）——
/// 對面改了欄位而本側沒跟上時，壞的是測試，不是某一次真的送出去。
///
/// **線上形狀是編譯器合成的那一種**：帶關聯值的列舉在 `Codable` 合成下編成
/// `{"<case>":{"_0":{…}}}`，欄位名取自 `CodingKeys`（兩側都沒有設 key 轉換策略），本側因此
/// 得以在屬性名不同於線上鍵名時逐欄釘住對應。case 名與線上欄位名都是協議的一部分，改名即改協議。
///
/// **參數型別做成巢狀**：它們對這則請求以外的任何地方都沒有意義，攤成頂層型別只是讓五個
/// 只有這裡用得到的名字佔住整個模組的命名空間。
internal enum NymphRequest: Encodable, Equatable, Sendable {

    /// 開一個 guest：複製基底、開機、等到可以收命令。
    case spawn(SpawnParams)

    /// 在既有 guest 裡跑一道命令。
    case execute(ExecuteParams)

    /// 列出 guest。
    case list(ListParams)

    /// 查單一 guest 的狀態。
    case status(StatusParams)

    /// 停掉並清除一個 guest。
    case destroy(DestroyParams)

    /// `spawn` 的參數。
    ///
    /// **每一欄都要送出去**：對面是合成的 `Decodable`，非可選欄位缺席即整則解碼失敗——本側
    /// 的預設值只在本側成立，不會在線上補齊。
    internal struct SpawnParams: Encodable, Equatable, Sendable {

        /// 基底別名；由 daemon 解析成實際位置。
        internal var golden: String

        /// 要開哪一種 guest；對面必填、無預設。
        internal var os: NymphGuestKind

        /// 要求的 vCPU 數。
        internal var cpus: Int

        /// 要求的記憶體，GiB。
        internal var memoryGiB: Int

        /// 是否等到可以收命令才回。
        internal var wait: Bool

        /// 等待上限，秒。
        internal var readinessTimeoutSeconds: Int
    }

    /// `execute` 的參數。
    internal struct ExecuteParams: Encodable, Equatable, Sendable {

        /// 目標 guest 的識別碼。
        internal var identifier: String

        /// 命令，逐個參數。
        internal var command: [String]

        /// 整體逾時秒數；nil 表示不由對面設限。
        internal var timeoutSeconds: Int?

        /// 餵給命令的標準輸入；nil 表示沒有輸入。
        internal var standardInput: String?

        /// 執行前切到哪個目錄；nil 表示登入時的預設目錄。
        internal var workingDirectory: String?

        /// 額外環境變數。
        internal var environment: [String: String]

        /// 對應線上欄位名；同名者一併列出，屬性改名時線上鍵才不會跟著動。
        private enum CodingKeys: String, CodingKey {

            /// 線上鍵 `id`；屬性名依「識別字不縮寫」展開，兩側靠這一行對上。
            case identifier = "id"

            /// 線上鍵 `command`。
            case command

            /// 線上鍵 `timeoutSeconds`。
            case timeoutSeconds

            /// 線上鍵 `standardInput`。
            case standardInput

            /// 線上鍵 `workingDirectory`。
            case workingDirectory

            /// 線上鍵 `environment`。
            case environment
        }
    }

    /// `list` 的參數。
    internal struct ListParams: Encodable, Equatable, Sendable {

        /// true 時連已停止的一併列出。
        internal var all: Bool
    }

    /// `status` 的參數。
    internal struct StatusParams: Encodable, Equatable, Sendable {

        /// 目標 guest 的識別碼。
        internal var identifier: String

        /// 對應線上欄位名。
        private enum CodingKeys: String, CodingKey {

            /// 線上鍵 `id`；屬性名依「識別字不縮寫」展開，兩側靠這一行對上。
            case identifier = "id"
        }
    }

    /// `destroy` 的參數。
    internal struct DestroyParams: Encodable, Equatable, Sendable {

        /// 目標 guest 的識別碼。
        internal var identifier: String

        /// true 時直接硬停，不等它自己收尾。
        internal var force: Bool

        /// 對應線上欄位名；同名者一併列出，屬性改名時線上鍵才不會跟著動。
        private enum CodingKeys: String, CodingKey {

            /// 線上鍵 `id`；屬性名依「識別字不縮寫」展開，兩側靠這一行對上。
            case identifier = "id"

            /// 線上鍵 `force`。
            case force
        }
    }
}
