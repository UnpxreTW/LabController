//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一項產物宣告本側收不收得了；收件與收集共用同一份判準。
///
/// 收件時（``JobAdmission``）與步驟跑完收集時（``JobRunner``）各問一次：前者讓收不了的 job 一個
/// 步驟都不跑就紅，後者擋住不經收件、直接造出來的 ``JobPlan``。兩處各寫一份的話，遲早有一邊
/// 放行了另一邊會擋下的宣告——收件放行、收集才擋，等於把一件注定失敗的 job 跑完一整輪才紅。
extension JobArtifact {

	/// 本側收不了這一項宣告的原因；收得了時為 nil。
	///
	/// 只收 `paths`：`untracked`、`exclude`、`reports` 類與 zip 以外的格式都不收——照常跑完而少收
	/// 或多收檔案，站台端看到的會是一份內容不對的產物。上傳條件讀不懂不在這裡判：那是協議形狀的
	/// 問題，由 ``JobResponse/unreadableFields`` 記成讀不懂的欄位。
	internal var collectionRefusal: String? {
		guard ["", "archive"].contains(artifactType) else { return "種類 \(artifactType) 不是 archive" }
		guard ["", "zip"].contains(artifactFormat) else { return "打包格式 \(artifactFormat) 不是 zip" }
		guard !untracked else { return "要求連同未納入版本控制的檔案一起收" }
		guard exclude.isEmpty else { return "宣告了排除路徑" }
		for path in paths {
			// 與 runner 端同：產物只能來自程式碼目錄底下。
			guard !path.hasPrefix("/") else { return "路徑 \(path) 是絕對路徑" }
			guard !path.split(separator: "/").contains("..") else { return "路徑 \(path) 含有 `..`" }
			guard !path.contains("**") else { return "路徑 \(path) 含有 `**`，執行環境的 shell 展開不了" }
			// runner 端會先展開路徑裡的 CI 變數；這裡照字面比對，展開之後才成立的路徑會變成「沒有符合」，
			// job 照樣綠、產物卻少收。展開後的路徑也繞得過上面兩道檢查。
			guard !path.contains("$") else { return "路徑 \(path) 含有變數，本側不展開" }
		}
		return nil
	}
}
