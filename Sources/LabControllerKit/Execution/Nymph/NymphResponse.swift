//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// nymph daemon 回來的一則回應，本側的線上形狀；鏡像的理由與線上形狀見 ``NymphRequest``。
///
/// **錯誤也是一種回應**：對面把工具層的失敗包成 ``ToolError`` 從同一條線回來，而不是斷線或
/// 回一個空的成功。本側因此不能只看「有沒有收到東西」，要看收到的是哪一種。
internal enum NymphResponse: Decodable, Equatable, Sendable {

    /// `spawn` 成功。
    case spawn(SpawnResult)

    /// `execute` 成功；結束碼在裡面，非零不是錯誤。
    case execute(ExecuteResult)

    /// `list` 成功。
    case list(ListResult)

    /// `status` 成功。
    case status(StatusResult)

    /// `destroy` 成功。
    case destroy(DestroyResult)

    /// 對面明確拒絕或做不到；帶穩定的錯誤碼。
    case toolError(ToolError)

    /// `spawn` 的結果。
    internal struct SpawnResult: Decodable, Equatable, Sendable {

        /// 新 guest 的識別碼。
        internal var identifier: String

        /// 回來這一刻的狀態；等待逾時時會是尚未收斂的那一種。
        internal var state: NymphSessionState

        /// guest 的 IP；還沒解出或根本沒接網路時為 nil。
        internal var IP: String?

        /// 對應線上欄位名；同名者一併列出，屬性改名時線上鍵才不會跟著動。
        private enum CodingKeys: String, CodingKey {

            /// 線上鍵 `id`；屬性名依「識別字不縮寫」展開，兩側靠這一行對上。
            case identifier = "id"

            /// 線上鍵 `state`。
            case state

            /// 線上鍵 `ip`；屬性名依「縮寫詞全大寫」寫成 `IP`。
            case IP = "ip"
        }
    }

    /// `execute` 的結果。
    ///
    /// **兩道輸出在對面已經是文字**：線上是 JSON 字串，不是原始位元組。本側的
    /// ``CommandResult`` 收的是位元組，轉回去時已經過一次解碼——要逐 byte 比對的東西不該
    /// 走這條路徑，這是後端本身的限制、不是本側的取捨。
    internal struct ExecuteResult: Decodable, Equatable, Sendable {

        /// 標準輸出。
        internal var standardOutput: String

        /// 標準錯誤。
        internal var standardError: String

        /// 結束碼。
        internal var exit: Int32
    }

    /// 單一 guest 的摘要。
    internal struct SessionSummary: Decodable, Equatable, Sendable {

        /// 識別碼。
        internal var identifier: String

        /// 當下狀態。
        internal var state: NymphSessionState

        /// IP；未解出為 nil。
        internal var IP: String?

        /// 開這個 guest 用的基底別名。
        internal var golden: String

        /// vCPU 數。
        internal var cpus: Int

        /// 記憶體，GiB。
        internal var memoryGiB: Int

        /// 已經開了幾秒。
        internal var uptimeSeconds: Int

        /// 對應線上欄位名；同名者一併列出，屬性改名時線上鍵才不會跟著動。
        private enum CodingKeys: String, CodingKey {

            /// 線上鍵 `id`；屬性名依「識別字不縮寫」展開，兩側靠這一行對上。
            case identifier = "id"

            /// 線上鍵 `state`。
            case state

            /// 線上鍵 `ip`；屬性名依「縮寫詞全大寫」寫成 `IP`。
            case IP = "ip"

            /// 線上鍵 `golden`。
            case golden

            /// 線上鍵 `cpus`。
            case cpus

            /// 線上鍵 `memoryGiB`。
            case memoryGiB

            /// 線上鍵 `uptimeSeconds`。
            case uptimeSeconds
        }
    }

    /// `list` 的結果。
    internal struct ListResult: Decodable, Equatable, Sendable {

        /// 各 guest 的摘要；空表是正常結果。
        internal var sessions: [SessionSummary]
    }

    /// `status` 的結果。
    internal struct StatusResult: Decodable, Equatable, Sendable {

        /// guest 摘要。
        internal var summary: SessionSummary

        /// 停止的原因；還在跑時為 nil。
        internal var stopReason: String?
    }

    /// `destroy` 的結果。
    internal struct DestroyResult: Decodable, Equatable, Sendable {

        /// 被清掉的識別碼。
        internal var identifier: String

        /// 恆為 true；查無此 guest 走 ``ToolError``、不走這裡。
        internal var destroyed: Bool

        /// 對應線上欄位名；同名者一併列出，屬性改名時線上鍵才不會跟著動。
        private enum CodingKeys: String, CodingKey {

            /// 線上鍵 `id`；屬性名依「識別字不縮寫」展開，兩側靠這一行對上。
            case identifier = "id"

            /// 線上鍵 `destroyed`。
            case destroyed
        }
    }

    /// 對面的工具層失敗。
    ///
    /// **判別一律看 `code`、不看 `message`**：`code` 是對面承諾穩定的那一半，`message` 帶的是
    /// 給人看的脈絡（含識別碼與原文），措辭改一次就會讓比對訊息字串的那條路徑靜默失效。
    internal struct ToolError: Decodable, Equatable, Sendable {

        /// 穩定錯誤碼。
        internal var code: String

        /// 人讀訊息。
        internal var message: String
    }
}
