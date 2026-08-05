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
/// ⚠️ 押住的尾巴存的是**已遮過**的文字，下一輪會再遮一次。這在片語本身是遮蔽字樣
/// `[MASKED]` 之子字串時會反覆改寫——但站台端的遮蔽變數限制（長度下限、且字元集不含
/// 方括號）讓那種值建不出來，故不另設防。
public struct MaskedTraceStream: Sendable {

    /// 套用的遮蔽規則。
    public let masker: TraceMasker

    /// 尚未放行的尾段。
    private var pending: String = ""

    /// 以遮蔽規則建立。
    public init(masker: TraceMasker) {
        self.masker = masker
    }

    /// 餵入一段原始 trace，回傳此刻可以安全送出的內容（可能為空字串）。
    public mutating func append(_ chunk: String) -> String {
        pending += chunk
        let masked: String = masker.mask(pending)
        // 片語最長 n 個字元時，尾端 n-1 個字元都還可能是某個片語的開頭，不能放。
        let holdBack: Int = max(masker.longestPhraseLength - 1, 0)
        guard masked.count > holdBack else {
            pending = masked
            return ""
        }
        let cut: String.Index = masked.index(masked.endIndex, offsetBy: -holdBack)
        pending = .init(masked[cut...])
        return .init(masked[..<cut])
    }

    /// job 結束時把緩衝區剩下的內容全部放行。
    ///
    /// 不呼叫這支就收工，最後幾個字元會留在記憶體裡永遠送不出去——trace 尾巴缺一小截、
    /// 而且缺得毫無徵兆。
    public mutating func flush() -> String {
        let remaining: String = pending
        pending = ""
        return masker.mask(remaining)
    }
}
