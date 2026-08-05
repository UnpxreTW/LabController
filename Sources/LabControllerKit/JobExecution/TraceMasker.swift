//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 把標了 `masked` 的變數值自 trace 內容抹掉的遮蔽規則。
///
/// 行為對齊 gitlab-runner v16.2 `helpers/trace/internal/masker`：命中處換成固定字樣、
/// 空字串不當片語、重複片語去重，且**長片語優先**——短片語先命中會把長片語切成兩半、
/// 讓剩下的尾巴原樣露出來。
public struct TraceMasker: Sendable, Equatable {

    /// 命中時填回去的字樣；與上游一致，方便讀 log 的人一眼認出是被遮的、不是原本就長這樣。
    public static let maskToken: String = "[MASKED]"

    /// 要遮的片語；已去空、去重，並依長度由長至短排序。
    public let phrases: [String]

    /// 以片語清單建立。
    public init(maskedValues: [String]) {
        var seen: Set<String> = []
        var unique: [String] = []
        for value in maskedValues where !value.isEmpty {
            guard seen.insert(value).inserted else { continue }
            unique.append(value)
        }
        self.phrases = unique.sorted { $0.count > $1.count }
    }

    /// 自 job 變數取出所有標了 `masked` 的值建立。
    public init(variables: [JobVariable]) {
        self.init(maskedValues: variables.filter(\.masked).map(\.value))
    }

    /// 遮蔽一段**內容已完整**的文字。
    ///
    /// 分段串流的 trace 不要直接用這支：值很可能橫跨兩段、各自遮都不命中。那個情境走
    /// `MaskedTraceStream`。
    public func mask(_ text: String) -> String {
        var masked: String = text
        for phrase in phrases {
            masked = masked.replacingOccurrences(of: phrase, with: Self.maskToken)
        }
        return masked
    }

    /// 最長片語的長度；串流遮蔽時據此決定要押住多少尾巴。
    var longestPhraseLength: Int {
        phrases.first?.count ?? 0
    }
}
