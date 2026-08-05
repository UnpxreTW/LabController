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
///
/// **一處比上游嚴**：上游是逐片語依序做字串取代，兩個片語在文字裡互相重疊時（A 的尾巴
/// ＝B 的頭），先替掉 A 會讓 B 露出沒被 A 蓋到的那一截。這裡改成單趟掃描、把所有片語的
/// 命中區間聯集起來一次遮掉，任何屬於某個片語的字元都不會留在輸出裡。多遮幾個字元的代價
/// 遠小於漏出秘密的一小段。
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

    /// 自 job 變數建立，另外無條件把 job token 也列為片語。
    ///
    /// **token 沒有 `masked` 旗標可以依靠**：站台不會把它當成變數送過來，但它會從別的
    /// 路徑走進 trace——最典型的是 `git_info.repo_url` 內嵌的 userinfo，clone 失敗時
    /// git 會把完整 remote URL 印進 stderr。一枚仍在有效期內的 token 就這樣留在任何
    /// 專案成員都讀得到的 log 裡。多遮一個字串的成本是零，沒有反面。
    public init(variables: [JobVariable], jobToken: String) {
        self.init(maskedValues: variables.filter(\.masked).map(\.value) + [jobToken])
    }

    /// 遮蔽一段**內容已完整**的文字。
    ///
    /// 分段串流的 trace 不要直接用這支：值很可能橫跨兩段、各自遮都不命中。那個情境走
    /// `MaskedTraceStream`。
    ///
    /// 作法是先標出所有片語的命中區間、再把相鄰或重疊的區間併成一段輸出一個遮蔽字樣，
    /// 因此 `AKIAsecret`／`secretXYZ` 兩個片語同時出現在 `AKIAsecretXYZ` 裡時整段被遮掉，
    /// 不會留下 `XYZ`。
    public func mask(_ text: String) -> String {
        guard !phrases.isEmpty, !text.isEmpty else { return text }
        let characters: [Character] = .init(text)
        let covered: [Bool] = coverage(of: characters)
        var masked: String = ""
        var index: Int = 0
        while index < characters.count {
            guard covered[index] else {
                masked.append(characters[index])
                index += 1
                continue
            }
            masked += Self.maskToken
            while index < characters.count, covered[index] {
                index += 1
            }
        }
        return masked
    }

    /// 標出每個字元是否落在某個片語的命中區間內。
    ///
    /// 串流遮蔽要靠這份標記決定切點：切在命中區間中間會把一個還沒完成的比對截斷，
    /// 因此切點必須避開任何區間內部。
    func coverage(of characters: [Character]) -> [Bool] {
        var covered: [Bool] = .init(repeating: false, count: characters.count)
        for phrase in phrases {
            let pattern: [Character] = .init(phrase)
            guard pattern.count <= characters.count else { continue }
            for start in 0 ... (characters.count - pattern.count)
            where characters[start...].starts(with: pattern) {
                for offset in start ..< (start + pattern.count) {
                    covered[offset] = true
                }
            }
        }
        return covered
    }

    /// 最長片語的長度；串流遮蔽時據此決定要押住多少尾巴。
    var longestPhraseLength: Int {
        phrases.first?.count ?? 0
    }
}
