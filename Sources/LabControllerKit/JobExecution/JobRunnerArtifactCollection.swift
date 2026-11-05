//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// ``JobRunner`` 在步驟跑完之後收產物的那一段：在執行環境裡打包，再分塊取回本側。
///
/// 與本體分開擺的理由同 ``JobRunner/FirstFailure``：腳本怎麼寫、輸出怎麼拼回一份檔案是一整套
/// 自己的規則，混進逐步驟的流程裡兩邊都不好讀。
///
/// **為什麼分塊、為什麼是文字**：命令的兩道輸出在後端那一側已經是文字（見
/// ``NymphExecutionBackend``），打包好的檔案是二進位，只能編碼成 base64 帶回來；一次帶整份
/// 則單一回應的大小沒有上限。每塊固定位元組數（``JobRunner/artifactChunkSize``），本側逐塊核對
/// 長度，任何一塊對不上都算收集失敗、不交出半份檔案。
///
/// **路徑由本側決定**：腳本與打包檔都以宣告的索引命名、落在工作根底下的 `artifacts/`，與步驟
/// 腳本取索引不取名字的理由相同。宣告裡的路徑以單引號字面寫進腳本，在執行環境裡只做路徑展開
/// （不經 `eval`、不做命令替換），展開的起點是取回的程式碼目錄。
///
/// - Important: 只收 `paths`：`untracked`、`exclude`、`reports` 類與 zip 以外的格式都不在這裡
///   處理，遇到就算收集失敗——照常跑完而少收或多收檔案，站台端看到的會是一份內容不對的產物。
extension JobRunner {

	// MARK: Public

	/// 取回產物時每一塊的位元組數。
	///
	/// 打包好的檔案經命令輸出帶回來，而那一道輸出是文字、整份放進一則回應（見
	/// ``NymphExecutionBackend``）——分塊是為了讓單一回應的大小有上限。8 MiB 編碼成 base64 之後
	/// 約 11 MiB，在一則回應裡仍是可以整份讀進記憶體的量級。
	public static let artifactChunkSize: Int = 8 * 1024 * 1024

	/// 一份打包檔最多收多少位元組；執行環境回報更大的值時算收集失敗。
	///
	/// 這個數字由執行環境裡的腳本印出來，而那個環境跑的是 CI 檔的程式碼——profile 裡一個同名函式
	/// 就能讓它印出任意值。不設上限的話，一個極大的值會讓本側在算塊數或配置記憶體時崩潰，崩掉的
	/// 是整個 controller 行程、不只這一件 job。取 4 GiB：產物整份在記憶體裡，比這更大的量級本來
	/// 就不是這條路徑接得住的。
	public static let artifactSizeLimit: Int = 4 * 1024 * 1024 * 1024

	// MARK: Internal

	/// 收產物的結果。
	internal struct ArtifactCollection {

		/// 已打包取回的產物，依宣告順序。
		internal var artifacts: [CollectedArtifact] = []

		/// 有沒有任何一份沒收成；收成之前的那幾份仍在 ``artifacts`` 裡。
		internal var hasFailed: Bool = false
	}

	/// 開機時要放進環境的全部檔案：鋪好的檔案樹，有宣告產物時再加上收集腳本。
	///
	/// - Parameters:
	///   - plan: 消化過的 payload。
	///   - workspace: 已鋪好的檔案樹；取它的注入檔、工作根與程式碼目錄。
	/// - Returns: 檔案樹的注入檔；有宣告產物時接著每項一份打包腳本，外加一份共用的分塊讀取腳本。
	/// - Throws: ``InjectedFileError``。
	internal static func injectedFiles(for plan: JobPlan, in workspace: JobWorkspace) throws -> [InjectedFile] {
		guard !plan.artifacts.isEmpty else { return workspace.injectedFiles }
		var files: [InjectedFile] = workspace.injectedFiles
		for (index, declaration) in plan.artifacts.enumerated() {
			let script: String = packingScript(
				patterns: declaration.paths,
				from: workspace.checkoutDirectory,
				into: archivePath(at: index, in: workspace)
			)
			try files.append(.init(path: packingScriptPath(at: index, in: workspace), contents: .init(script.utf8)))
		}
		try files.append(.init(path: readingScriptPath(in: workspace), contents: .init(readingScript.utf8)))
		return files
	}

	/// 步驟跑完之後收尾：有宣告產物就先收，再定這件 job 的結果。
	///
	/// 收產物仍在看門線的管轄內：它在跑 job 的那一條工作線上，預算用完時環境照樣被焚毀。開始收
	/// 之前再比一次時間上限，已經到了就不收，死因的判法同步驟邊界那一道。
	///
	/// - Parameters:
	///   - plan: 消化過的 payload。
	///   - workspace: 已鋪好的檔案樹。
	///   - guest: 已經開好的環境。
	///   - deadline: 這件 job 的時間上限。
	///   - hasFailed: 有沒有步驟失敗過。
	///   - failure: 第一個失敗步驟的結束碼。
	///   - trace: 抄本。
	/// - Returns: 這次的結果。
	/// - Throws: ``ExecutionBackendError``，同步驟。
	internal func finish(
		_ plan: JobPlan,
		in workspace: JobWorkspace,
		on guest: GuestIdentifier,
		before deadline: Date,
		afterFailure hasFailed: Bool,
		failing failure: FirstFailure,
		recording trace: TraceRecorder
	) async throws -> JobRunReport {
		guard !plan.artifacts.isEmpty else {
			guard hasFailed else { return finished(plan, as: .completed, exitCode: 0, recording: trace) }
			return finished(plan, as: .jobFailed, reason: .scriptFailure, exitCode: failure.exitCode, recording: trace)
		}
		let collectingAt: Date = now()
		guard collectingAt < deadline else {
			trace.write("已達本次 job 的時間上限（\(plan.timeoutSeconds) 秒），產物不再收集。")
			guard hasFailed else {
				return finished(plan, as: .timeout, reason: .jobExecutionTimeout, exitCode: nil, recording: trace)
			}
			return finished(plan, as: .jobFailed, reason: .scriptFailure, exitCode: failure.exitCode, recording: trace)
		}
		trace.mark("artifacts", at: collectingAt)
		let collection: ArtifactCollection = try await collectArtifacts(
			plan,
			in: workspace,
			on: guest,
			afterFailure: hasFailed,
			recording: trace
		)
		guard hasFailed || collection.hasFailed else {
			return finished(plan, as: .completed, exitCode: 0, carrying: collection.artifacts, recording: trace)
		}
		// 收不成只在 job 本身成功時改寫終態，與上傳失敗同一條規則（見 `JobArtifactUploadSummary`）：
		// job 自己的失敗優先，收產物的失敗其次。後者的結束碼為 nil——沒有任何一個步驟的結束碼決定了
		// 這個結果。
		return finished(
			plan,
			as: .jobFailed,
			reason: .scriptFailure,
			exitCode: hasFailed ? failure.exitCode : nil,
			carrying: collection.artifacts,
			recording: trace
		)
	}

	/// 依上傳條件逐項打包並取回；第一份沒收成就停。
	///
	/// - Parameters:
	///   - plan: 消化過的 payload。
	///   - workspace: 已鋪好的檔案樹。
	///   - guest: 已經開好的環境。
	///   - hasFailed: 這件 job 是否已經失敗；拿去問每一項的上傳條件。
	///   - trace: 抄本。
	/// - Returns: 收到的產物與有沒有失敗。
	/// - Throws: ``ExecutionBackendError``——命令根本沒送進去，與步驟同樣收成環境層失敗。
	internal func collectArtifacts(
		_ plan: JobPlan,
		in workspace: JobWorkspace,
		on guest: GuestIdentifier,
		afterFailure hasFailed: Bool,
		recording trace: TraceRecorder
	) async throws -> ArtifactCollection {
		var collection: ArtifactCollection = .init()
		for (index, declaration) in plan.artifacts.enumerated() {
			let filename: String = declaration.uploadFilename
			// 先於上傳條件判：讀不懂的條件已經回落成 `on_success`，先問條件的話，job 失敗時這一項會以
			// 一個站台沒有給過的條件被略過。
			if let condition: String = declaration.unrecognisedUploadCondition {
				trace.write("產物 \(filename) 收不了：上傳條件 \(condition) 讀不懂。其餘產物不再收集。")
				collection.hasFailed = true
				return collection
			}
			guard declaration.uploadCondition.shouldRun(afterFailure: hasFailed) else {
				trace.write("略過產物 \(filename)：它的上傳條件是 \(declaration.uploadCondition.rawValue)。")
				continue
			}
			if let reason: String = Self.unsupportedReason(of: declaration) {
				trace.write("產物 \(filename) 收不了：\(reason)。其餘產物不再收集。")
				collection.hasFailed = true
				return collection
			}
			trace.write("$ 收集產物 \(filename)")
			let packing: CommandResult = try await backend.exec(
				configuration.shell + [Self.packingScriptPath(at: index, in: workspace)],
				in: guest
			)
			if !packing.standardErrorText.isEmpty {
				trace.write(packing.standardErrorText)
			}
			guard packing.isSuccess else {
				trace.write("產物 \(filename) 打包失敗（結束碼 \(packing.exitCode)）。其餘產物不再收集。")
				collection.hasFailed = true
				return collection
			}
			guard let size: Int = Self.packedSize(from: packing.standardOutputText) else {
				trace.write("產物 \(filename) 的打包結果讀不懂。其餘產物不再收集。")
				collection.hasFailed = true
				return collection
			}
			guard size <= Self.artifactSizeLimit else {
				trace.write("產物 \(filename) 有 \(size) 位元組，超過上限 \(Self.artifactSizeLimit) 位元組。其餘產物不再收集。")
				collection.hasFailed = true
				return collection
			}
			guard size > 0 else {
				// 同 runner 端：一個檔案都沒有符合時只留警告、不算失敗，也沒有東西要送。
				trace.write("產物 \(filename) 沒有符合的檔案，不上傳。")
				continue
			}
			let retrieval: Result<Data, RetrievalFailure> = try await retrieve(
				Self.archivePath(at: index, in: workspace),
				size: size,
				in: workspace,
				on: guest,
				recording: trace
			)
			guard case let .success(archive) = retrieval else {
				if case let .failure(failure) = retrieval {
					trace.write("產物 \(filename) 取回失敗：\(failure.reason)。其餘產物不再收集。")
				}
				collection.hasFailed = true
				return collection
			}
			collection.artifacts.append(.init(declaration: declaration, archive: archive))
			trace.write("產物 \(filename) 已打包取回（\(size) 位元組）。")
		}
		return collection
	}

	// MARK: Private

	/// 一份打包檔沒取回來的原因。
	private struct RetrievalFailure: Error {

		/// 寫進 trace 的那一段說明。
		fileprivate let reason: String
	}

	/// 打包腳本印大小的那一行開頭；本側只認最後一個以它開頭的行。
	///
	/// 不取「最後一行」：登入 shell 結束時可能還會執行 `~/.bash_logout`，它印的東西會落在後面。
	private static let packedMarker: String = "labcontroller-packed "

	/// 分塊讀取腳本在每一塊之前印的那一行；本側只取它之後的輸出。
	///
	/// 存在理由是登入 shell：跑腳本的命令預設走 `-l`，profile 印出來的任何文字都會先落在標準輸出，
	/// 而 base64 的字元集涵蓋一般文字——不切開的話，那幾個字會被當成檔案內容解進去。
	private static let chunkMarker: String = "labcontroller-chunk"

	/// 分塊讀取腳本的全文；兩個位置參數依序是打包檔路徑與第幾塊（從 0 起）。
	///
	/// `dd` 的區塊大小寫成位元組數：`8m` 與 `8M` 兩種寫法各只有一種平台的 `dd` 認得。
	private static var readingScript: String {
		"""
		# 由 LabController 產生；隨執行環境焚毀。
		set -e
		set -o pipefail
		echo \(chunkMarker)
		dd if="$1" bs=\(artifactChunkSize) skip="$2" count=1 2>/dev/null | base64

		"""
	}

	/// 一項宣告的打包腳本：在程式碼目錄裡展開每一條路徑、打成 zip，印出大小或 `none`。
	///
	/// `IFS` 清空之後，未加引號的 `$pattern` 只做路徑展開、不再斷詞；`nullglob` 讓沒有符合的
	/// pattern 展開成空，而不是原樣留下一個不存在的名字。不用 `**`：執行環境的 bash 可能是 3.2，
	/// 沒有 `globstar`。
	private static func packingScript(patterns: [String], from directory: String, into archive: String) -> String {
		"""
		# 由 LabController 產生；隨執行環境焚毀。
		set -e
		set -o pipefail
		shopt -s nullglob
		mkdir -p \(singleQuoted(directory))
		cd \(singleQuoted(directory))
		archive=\(singleQuoted(archive))
		patterns=(\(patterns.map(singleQuoted).joined(separator: " ")))
		rm -f "$archive"
		if ! command -v zip >/dev/null 2>&1; then
			echo "執行環境裡沒有 zip，產物無法打包。" >&2
			exit 1
		fi
		files=()
		IFS=
		for pattern in "${patterns[@]}"; do
			matched=0
			for file in $pattern; do
				if [ -e "$file" ] || [ -L "$file" ]; then
					files+=("$file")
					matched=1
				fi
			done
			if [ "$matched" -eq 0 ]; then
				echo "沒有符合 $pattern 的檔案。" >&2
			fi
		done
		if [ "${#files[@]}" -eq 0 ]; then
			echo "\(packedMarker)none"
		else
			zip -q -r -y "$archive" -- "${files[@]}"
			echo "\(packedMarker)$(wc -c < "$archive" | tr -d ' ')"
		fi

		"""
	}

	/// 本側收不了這一項宣告的原因；收得了時為 nil。
	private static func unsupportedReason(of declaration: JobArtifact) -> String? {
		guard ["", "archive"].contains(declaration.artifactType) else {
			return "種類 \(declaration.artifactType) 不是 archive"
		}
		guard ["", "zip"].contains(declaration.artifactFormat) else {
			return "打包格式 \(declaration.artifactFormat) 不是 zip"
		}
		guard !declaration.untracked else { return "要求連同未納入版本控制的檔案一起收" }
		guard declaration.exclude.isEmpty else { return "宣告了排除路徑" }
		for path in declaration.paths {
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

	/// 打包腳本說的大小；`none` 為 0，讀不懂時為 nil。
	private static func packedSize(from output: String) -> Int? {
		let lines: [Substring] = output.split(whereSeparator: \.isNewline)
		guard let line: Substring = lines.last(where: { $0.hasPrefix(packedMarker) }) else { return nil }
		let value: Substring = line.dropFirst(packedMarker.count)
		guard value != "none" else { return 0 }
		guard let size: Int = .init(value), size > 0 else { return nil }
		return size
	}

	/// 一塊的內容：分隔行之後的 base64 解碼結果；找不到分隔行或解不開時為 nil。
	private static func chunk(from output: String) -> Data? {
		let lines: [Substring] = output.split(separator: "\n", omittingEmptySubsequences: false)
		guard let marker: Int = lines.lastIndex(where: { $0 == chunkMarker }) else { return nil }
		let encoded: String = lines[(marker + 1)...].joined()
		return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
	}

	/// 第 `index` 項宣告的打包腳本路徑。
	private static func packingScriptPath(at index: Int, in workspace: JobWorkspace) -> String {
		"\(workspace.root)/artifacts/pack-\(index).sh"
	}

	/// 第 `index` 項宣告的打包檔路徑；落在程式碼目錄之外，免得把自己也收進去。
	private static func archivePath(at index: Int, in workspace: JobWorkspace) -> String {
		"\(workspace.root)/artifacts/\(index).zip"
	}

	/// 分塊讀取腳本的路徑。
	private static func readingScriptPath(in workspace: JobWorkspace) -> String {
		"\(workspace.root)/artifacts/read.sh"
	}

	/// 把字串包成 shell 的單引號字面；寫法與理由同 ``JobWorkspace`` 的變數檔。
	private static func singleQuoted(_ value: String) -> String {
		"'" + value.replacing("'", with: "'\\''") + "'"
	}

	/// 收尾成一份結果；trace 在此刻收攏，之後不再寫入。
	private func finished(
		_ plan: JobPlan,
		as outcome: JobOutcome,
		reason: JobFailureReason? = nil,
		exitCode: Int32?,
		carrying artifacts: [CollectedArtifact] = [],
		recording trace: TraceRecorder
	) -> JobRunReport {
		trace.mark("finish", at: now())
		return .init(
			outcome: outcome,
			failureReason: reason,
			exitCode: exitCode,
			trace: trace.finish(),
			warnings: plan.warnings,
			artifacts: artifacts
		)
	}

	/// 逐塊取回一份打包檔；任何一塊沒拿到或長度不符就停，失敗那一塊的標準錯誤寫進 trace。
	private func retrieve(
		_ archivePath: String,
		size: Int,
		in workspace: JobWorkspace,
		on guest: GuestIdentifier,
		recording trace: TraceRecorder
	) async throws -> Result<Data, RetrievalFailure> {
		let chunkCount: Int = size / Self.artifactChunkSize + (size % Self.artifactChunkSize == 0 ? 0 : 1)
		var archive: Data = .init()
		for index in 0 ..< chunkCount {
			let expected: Int = min(Self.artifactChunkSize, size - index * Self.artifactChunkSize)
			let result: CommandResult = try await backend.exec(
				configuration.shell + [Self.readingScriptPath(in: workspace), archivePath, String(index)],
				in: guest
			)
			let position: String = "第 \(index + 1)／\(chunkCount) 塊"
			guard result.isSuccess else {
				if !result.standardErrorText.isEmpty {
					trace.write(result.standardErrorText)
				}
				return .failure(.init(reason: "\(position)以結束碼 \(result.exitCode) 結束"))
			}
			let received: Data? = Self.chunk(from: result.standardOutputText)
			guard let received, received.count == expected else {
				return .failure(.init(reason: "\(position)預期 \(expected) 位元組、收到 \(received?.count ?? 0) 位元組"))
			}
			archive.append(received)
		}
		return .success(archive)
	}
}
