//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 一項產物在執行環境裡打成哪一種檔。
///
/// 站台對每個種類規定一種格式，上傳時兩者對不上就拒收：`archive` 是 zip、`junit` 是 gzip、
/// `codequality` 是不壓縮的單一檔案（raw）。本側只收這三個種類，其餘 `reports` 類拒收。三種
/// 格式的打法照 runner 端：
///
/// - zip：所有符合的檔案打成一份 zip，連結以連結本身收進去。
/// - gzip：每個符合的檔案各壓成一段 gzip、依序接成一份，站台逐段解開；只收一般檔案，連結也不收。
/// - raw：只能有一個符合的檔案，原樣送出；連結照指向的檔案送。空檔不收：打包結果為 0 位元組時，
///   本側無從與「沒有符合的檔案」區分。
///
/// 幾條 pattern 展開出同一條路徑時只算一次（打包腳本展開時去重），與 runner 端以路徑為鍵收檔相同。
internal enum JobArtifactPacking: String, Sendable {

	/// 一份 zip。
	case zip

	/// 每個檔案一段 gzip、接成一份。
	case gzip

	/// 單一檔案原樣。
	case raw

	// MARK: Internal

	/// 本側收得了的種類與各自的格式；鍵是 `artifact_type`。
	internal static let formats: [String: Self] = [
		"archive": .zip,
		"junit": .gzip,
		"codequality": .raw
	]

	/// 執行環境裡必須有的工具；打包腳本開頭先檢查，沒有就打包失敗。
	internal var tool: String {
		switch self {
		case .zip:
			"zip"
		case .gzip:
			"gzip"
		case .raw:
			"cp"
		}
	}

	/// 打包腳本裡把 `files` 陣列裡的檔案寫成 `$archive` 的那一段；只在至少有一個檔案時執行。
	///
	/// 任何一個檔案不合這個格式的條件就以非零結束碼離開，本側收成打包失敗——照常送出的話，
	/// 站台收到的會是一份內容不對的產物。
	internal var command: String {
		switch self {
		case .zip:
			"""
			zip -q -r -y "$archive" -- "${files[@]}"
			"""
		case .gzip:
			"""
			for file in "${files[@]}"; do
				if [ -L "$file" ] || [ ! -f "$file" ]; then
					echo "$file 不是一般檔案，gzip 格式的產物只收一般檔案。" >&2
					exit 1
				fi
				gzip -c -- "$file" >> "$archive"
			done
			"""
		case .raw:
			"""
			if [ "${#files[@]}" -gt 1 ]; then
				echo "符合的檔案有 ${#files[@]} 個，raw 格式的產物只能有一個。" >&2
				exit 1
			fi
			if [ ! -f "${files[0]}" ]; then
				echo "${files[0]} 不是一般檔案，raw 格式的產物只收一般檔案。" >&2
				exit 1
			fi
			if [ ! -s "${files[0]}" ]; then
				echo "${files[0]} 是空檔，raw 格式的產物不收空檔。" >&2
				exit 1
			fi
			cp -- "${files[0]}" "$archive"
			"""
		}
	}
}
