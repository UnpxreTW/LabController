//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 登記簿本身沒能讀成或寫成。
///
/// 與 ``ExecutionBackendError`` 分開：那一族講的是執行環境那一側出了事，這一族講的是本機
/// 這份紀錄出了事。兩者的處置並不相同——登記簿讀不成只表示這一次不回收，而環境開不起來是
/// 一件 job 跑不成。
public enum GuestRegistryError: Error, Equatable, Sendable {

	/// 檔案在、但讀不成或解不開；`detail` 是給本側日誌看的。
	///
	/// **與「檔案不在」刻意分開**：沒有檔案是正常路徑（第一次跑、或上一次乾淨收工），而內容
	/// 壞掉是異常。兩者混成同一種答案時，壞掉的那一次會被靜靜地當成「沒有東西要回收」。
	case unreadable(path: String, detail: String)

	/// 寫不進去；`detail` 是給本側日誌看的。
	case notWritable(path: String, detail: String)

	/// 這份登記簿已經被另一個行程佔著。
	///
	/// **這是一種要當場停下來的錯，不是一種可以繞過去的狀況**：兩個行程共用同一份登記簿時，
	/// 後起來的那個會把前一個正在跑的環境當成上一輪的殘骸收掉。要在同一台機器上跑兩份，
	/// 各自給一份登記簿。
	case lockHeld(path: String)
}
