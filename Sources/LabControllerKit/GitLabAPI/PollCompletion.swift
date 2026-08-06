//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一輪輪詢走到哪裡收尾。
///
/// 三態分開表達的理由：`complete` 與 `truncated` 都是正常運作，但**只有 `complete` 代表
/// 「游標之後的資料本輪都看過了」**；把兩者壓成一個布林值，呼叫端就沒有辦法區分
/// 「沒事發生」與「事情多到讀不完」。`stalled` 更是必須浮上檯面——它是會自己重複下去的狀態。
public enum PollCompletion: Sendable, Equatable {

    /// 走到最後一頁。游標之後的資料本輪全數讀入。
    case complete

    /// 撞到翻頁預算、站台還有下一頁；游標已前進，下一輪從新游標接著讀。
    ///
    /// 不記「下一頁頁碼」是因為它下一輪就失效了：游標一動，站台的分頁邊界整個重算，
    /// 舊頁碼指向的位置與這一輪不是同一批資料。續讀一律從新游標的第一頁開始。
    case truncated

    /// 撞到翻頁預算、而且游標一步都沒能前進。
    ///
    /// 成因是預算內讀到的資料全部落在同一個游標秒數內——最典型的是一次交易批次改動大量資源，
    /// 它們共用同一個 `updated_at`。此時下一輪會讀到一模一樣的內容、再次撞牆，如此反覆，
    /// 而每一輪各自看起來都「成功」了。
    ///
    /// 這個狀態不會自己好，要靠調高翻頁預算或每頁筆數讓那一秒能被一輪讀完。
    case stalled
}
