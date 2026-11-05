//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一份已經打包好、等著送上站台的產物：宣告與打包後的檔案內容。
public struct CollectedArtifact: Sendable, Equatable {

	/// 這份產物的宣告；上傳時取檔名與查詢參數。
	public let declaration: JobArtifact

	/// 打包後的檔案內容。
	public let archive: Data

	/// 逐欄建立。
	///
	/// - Parameters:
	///   - declaration: 這份產物的宣告。
	///   - archive: 打包後的檔案內容。
	public init(declaration: JobArtifact, archive: Data) {
		self.declaration = declaration
		self.archive = archive
	}
}
