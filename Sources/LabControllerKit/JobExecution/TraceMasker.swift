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
    ///
    /// **internal、且本型別不把它印出來**：這裡裝的是 job token 與每一個 masked 變數的
    /// 明文值。留成 public 等於在任何 `print`／字串內插／測試失敗差異輸出裡放一份完整的
    /// 秘密清單——而讀到那行 log 的人不會知道自己正在看什麼。
    let phrases: [String]

    /// 因短於 `minimumPhraseLength` 而未列入的值數量。
    ///
    /// **丟棄不可以是靜默的**：「有東西被標成要遮、但我們沒遮」這件事本身必須看得見，
    /// 否則設定寫錯時沒有人會發現。這裡只記數量、不記內容。
    public let droppedPhraseCount: Int

    /// 片語數量；供呼叫端做健全性檢查，不洩漏內容。
    public var phraseCount: Int {
        phrases.count
    }

    /// 片語長度下限；短於此者不遮。
    ///
    /// 遮蔽的代價不是零：一個長度 1 的片語會命中幾乎每一行，整份 trace 變成一串遮蔽字樣，
    /// 讀 log 的人什麼都查不到——而那個長度的字串本來也不可能是憑證。**下限保護的是可讀性，
    /// 代價是短字串不遮**；job token 與站台的遮蔽變數都遠長於此，實務上落在下限以下的只有
    /// 測試替身與設定失誤。
    public static let minimumPhraseLength: Int = 4

    /// 以片語清單建立；空字串、重複值與短於下限者一律剔除。
    public init(maskedValues: [String]) {
        var seen: Set<String> = []
        var unique: [String] = []
        var dropped: Int = 0
        for value in maskedValues {
            guard value.count >= Self.minimumPhraseLength else {
                // 空字串不算「被丟棄的秘密」——那是沒有值，不是有值卻沒遮。
                dropped += value.isEmpty ? 0 : 1
                continue
            }
            guard seen.insert(value).inserted else { continue }
            unique.append(value)
        }
        self.phrases = unique.sorted { $0.count > $1.count }
        self.droppedPhraseCount = dropped
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
        return rendering(characters[...], covered: coverage(of: characters)[...])
    }

    /// 依既有的命中標記輸出文字：連續被標記的區間併成一個遮蔽字樣，其餘原樣保留。
    ///
    /// 標記與輸出分開，是為了讓串流那一側能把「上一輪已知被覆蓋」的資訊帶進來——那些
    /// 字元在本輪的緩衝區裡未必還能自己比中一個完整片語，但它們確實是秘密的一部分。
    func rendering(_ characters: ArraySlice<Character>, covered: ArraySlice<Bool>) -> String {
        var masked: String = ""
        var index: Int = characters.startIndex
        while index < characters.endIndex {
            guard covered[covered.startIndex + (index - characters.startIndex)] else {
                masked.append(characters[index])
                index += 1
                continue
            }
            masked += Self.maskToken
            while index < characters.endIndex,
                  covered[covered.startIndex + (index - characters.startIndex)] {
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

/// 印出來只給數量、不給內容。
///
/// 預設的反射輸出會把 `phrases` 整包吐出來，而那是 job token 加上每一個 masked 變數的
/// 明文。這三個協定把 `print`／字串內插／`debugPrint`／`dump` 四條路都收口——秘密不該
/// 因為某個人順手印了一個容器而外流。
extension TraceMasker: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// 只描述規模。
    public var description: String {
        "TraceMasker(phrases: \(phrases.count), dropped: \(droppedPhraseCount))"
    }

    /// 與 `description` 相同；debug 情境更需要這層保護，不是更不需要。
    public var debugDescription: String {
        description
    }

    /// `dump` 走 `Mirror`、繞過上面兩者，故一併收口成無子節點。
    public var customMirror: Mirror {
        .init(
            self,
            children: ["phrases": phrases.count, "droppedPhraseCount": droppedPhraseCount],
            displayStyle: .struct
        )
    }
}
