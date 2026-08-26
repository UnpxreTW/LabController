//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 隨工單一起帶進執行環境的一段規則原文。
///
/// **規則以原文內嵌、不以路徑引用**：執行環境裡沒有主控端那棵設定樹，任何 `~/…` 形狀的引用
/// 在對面都是死連結——而死連結的表現不是報錯，是那條規則安靜地沒有被讀到。
///
/// 只帶該 job 型用得到的片段、不整份塞：規則的正本仍只有一處，這裡帶的是選出來的節錄，
/// 兩邊都能改就會變成兩份正本。
public struct JobRuleFragment: Sendable, Equatable, Codable {

    /// 這段規則的名字（如 `git-force-push`）；供結果回報引用某一條時指得出來。
    public let name: String

    /// 規則原文。
    public let text: String

    /// 以顯式欄位建立。
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}
