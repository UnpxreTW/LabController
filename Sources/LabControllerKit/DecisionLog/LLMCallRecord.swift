//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一次本地 LLM 呼叫的帳目：哪顆模型、為什麼呼叫、花了多少 token 與時間。
///
/// 一次收齊四個欄位：`model`／`tokens`／`latencySeconds` 服務事故取證與吞吐量測，`purpose`
/// 服務成果歸類。另兩個截斷偵測用的計數（``promptEvalCount``／``evalCount``）是呼叫端量得到
/// 才有的值，做成 optional：現在多兩個 optional 欄位，比日後為它們升 schema 版本便宜。
///
/// ⚠ **這裡不放任何秘密**：模型名、用途、計數都不是憑證。job token 與 masked 變數的遮蔽發生
/// 在上游 trace 層（``TraceMasker``），這個型別結構上就沒有能裝下秘密的欄位——不是靠呼叫端
/// 記得別塞。
public struct LLMCallRecord: Sendable, Equatable, Codable {

    /// 呼叫的模型識別（如 `gpt-120b`）。
    public let model: String

    /// 呼叫的用途（如 `conflict_resolution`／`review`／`triage`）；供成果帳歸類。
    public let purpose: String

    /// 這次呼叫消耗的 token 總數。
    public let tokens: Int

    /// 這次呼叫的往返耗時（秒）。
    public let latencySeconds: Double

    /// 站台回報的 prompt 實際計入 token 數；截斷偵測靠它與估算值比對。閘道未提供時為 `nil`。
    public let promptEvalCount: Int?

    /// 站台回報的輸出 token 數。閘道未提供時為 `nil`。
    public let evalCount: Int?

    /// 以顯式欄位建立。
    public init(
        model: String,
        purpose: String,
        tokens: Int,
        latencySeconds: Double,
        promptEvalCount: Int? = nil,
        evalCount: Int? = nil
    ) {
        self.model = model
        self.purpose = purpose
        self.tokens = tokens
        self.latencySeconds = latencySeconds
        self.promptEvalCount = promptEvalCount
        self.evalCount = evalCount
    }
}
