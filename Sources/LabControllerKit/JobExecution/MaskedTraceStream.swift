//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 逐段餵入 trace、跨段邊界也遮得掉的遮蔽緩衝器。
///
/// **為什麼不能「每段各自遮完就送」**：trace 是分段回寫的，一個被遮的值很可能剛好橫跨
/// 兩段——前段收尾半截、後段開頭半截。兩段各自遮都不命中，於是完整的秘密就這樣在站台
/// 上被拼了回去。這裡的作法是每次只放行「確定不可能是某個片語前半」的部分，其餘押在
/// 緩衝區等下一段來會合。
///
/// ⚠️ **緩衝區存的是原文、不是遮過的文字**。存遮過的文字會壞在「一個片語是另一個片語的
/// 前綴」這個形狀上：短的那個在前半段就被完整命中並換成遮蔽字樣，原文當場銷毀，長的那個
/// 之後永遠再也匹配不到，於是它多出來的那一截跨段之後原樣送上站台。改存原文之後，切點
/// 另外要避開任何命中區間的內部——切在區間中間等同把一個還沒完成的比對截斷。
public struct MaskedTraceStream: Sendable {

    /// 套用的遮蔽規則。
    public let masker: TraceMasker

    /// 尚未放行的尾段；**存的是原文**，遮蔽只在放行的那一刻做。
    private var pending: String = ""

    /// `pending` 開頭已知落在命中區間內的字元數。
    ///
    /// 強制放行時帶過來的：那些字元在下一輪的緩衝區裡未必還能自己比中一個完整片語
    /// （前半已經被放掉了），但它們確實是秘密的一部分，不標起來就會在 `flush` 時裸奔。
    private var coveredPrefix: Int = 0

    /// 緩衝區字元數上限；超過即強制放行一段。
    ///
    /// 只有「片語首尾相接連續鋪滿」這一種形狀會逼到這裡——正常 trace 撐不到。定這個上限
    /// 是因為沒有它時該形狀會讓 trace **完全停送**、緩衝區隨輸出線性成長，而每輪都要重掃
    /// 整個緩衝區，整體退化成 O(n²)。站台端看到的會是一個「跑很久卻零輸出」的 job。
    ///
    /// 綁在最長片語上而非取固定值：每次 `append` 的成本正比於緩衝區長度，上限訂得越寬、
    /// 那個形狀下的每輪重掃就越貴。四倍足夠讓區間有空間跨過切點，又把成本壓在同一個數量級。
    private var bufferLimit: Int {
        max(4 * masker.longestPhraseLength, 64)
    }

    /// 以遮蔽規則建立。
    public init(masker: TraceMasker) {
        self.masker = masker
    }

    /// 餵入一段原始 trace，回傳此刻可以安全送出的內容（可能為空字串）。
    ///
    /// 押住的量最多是「最長片語長度 −1」再加上跨過切點的那一段命中區間，因此緩衝區不會
    /// 隨 trace 長度成長，只隨片語長度成長。
    public mutating func append(_ chunk: String) -> String {
        pending += chunk
        // 沒有片語＝透明通道，連押都不用押。
        guard masker.longestPhraseLength > 0 else {
            let released: String = pending
            pending = ""
            return released
        }
        let raw: [Character] = .init(pending)
        // 片語最長 n 個字元時，尾端 n-1 個字元都還可能是某個片語的開頭，不能放。
        let holdBack: Int = masker.longestPhraseLength - 1
        guard raw.count > holdBack else { return "" }
        let covered: [Bool] = markedCoverage(of: raw)
        var cut: Int = raw.count - holdBack
        // 切點落在命中區間內部時往前退到區間起點：切在中間會把還沒比完的區間截斷，
        // 前半被當成完整命中遮掉、後半留在緩衝區，於是原文被銷毀、長片語再也對不上。
        while cut > 0, cut < raw.count, covered[cut - 1], covered[cut] {
            cut -= 1
        }
        guard cut > 0 else { return forcedRelease(raw, holdBack: holdBack) }
        pending = .init(raw[cut...])
        coveredPrefix = 0
        return masker.rendering(raw[..<cut], covered: covered[..<cut])
    }

    /// 切點退到 0（整個緩衝區都在同一段命中區間內）時的出口。
    ///
    /// 退到 0 這件事本身就保證了 `raw[0 ..< raw.count - holdBack]` 全被覆蓋，因此整段換
    /// 一個遮蔽字樣即可、不會外洩；押住的尾巴同樣已知被覆蓋，用 `coveredPrefix` 帶到下一
    /// 輪。代價只是同一段秘密會被拆成兩個遮蔽字樣，換到的是「trace 一定會前進」。
    private mutating func forcedRelease(_ raw: [Character], holdBack: Int) -> String {
        guard raw.count > bufferLimit else { return "" }
        let cut: Int = raw.count - holdBack
        pending = .init(raw[cut...])
        coveredPrefix = holdBack
        return TraceMasker.maskToken
    }

    /// 取命中標記，並把上一輪帶過來的「已知被覆蓋」前綴補上。
    private func markedCoverage(of raw: [Character]) -> [Bool] {
        var covered: [Bool] = masker.coverage(of: raw)
        for index in 0 ..< min(coveredPrefix, raw.count) {
            covered[index] = true
        }
        return covered
    }

    /// job 結束時把緩衝區剩下的內容全部放行。
    ///
    /// 不呼叫這支就收工，最後幾個字元會留在記憶體裡永遠送不出去——trace 尾巴缺一小截、
    /// 而且缺得毫無徵兆。
    public mutating func flush() -> String {
        let raw: [Character] = .init(pending)
        let covered: [Bool] = markedCoverage(of: raw)
        pending = ""
        coveredPrefix = 0
        return masker.rendering(raw[...], covered: covered[...])
    }
}
