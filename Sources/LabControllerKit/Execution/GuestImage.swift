//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 要從哪一份基底開出執行環境。
///
/// 兩個 case 的差別是**信任面**而不是方便性：具名別名由後端自己解析，呼叫端不必知道基底
/// 實際存在哪裡；絕對路徑則直接指定主機上的一份基底，只有跑在受信任側的呼叫端用得到。
/// 不可信來源（模型、面板送進來的請求）一律只給得出別名——這道分野必須留在型別上，寫成
/// 「路徑欄位為空就當別名」的慣例時，沒有任何一處擋得住一個把路徑填進去的請求。
public enum GuestImage: Sendable, Equatable {

    /// 具名基底，由後端解析成實際位置。常規路徑。
    case alias(String)

    /// 主機上的絕對路徑，逃生梯用。
    case path(String)
}
