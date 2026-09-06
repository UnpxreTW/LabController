//
//  GenerateVersion
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import PackagePlugin

/// 建置前由 git 標籤推導版本字串，產生 `LabControllerVersion` 常數檔。
///
/// 版本字串不寫死在原始碼裡：每次建置都重新問一次工作目錄的 git，發版時只要打標籤，
/// 送給站台的 runner 自述就跟著走。取不到 git 資訊時（例如以套件相依身分被取用、
/// 或壓縮包解出來的樹）回落 `unknown`，不猜一個看起來像版本、實際對不上的值。
@main
internal struct GenerateVersionPlugin: BuildToolPlugin {

    /// 產生版本常數檔的 shell 腳本；`$0` 為顯示名、`$1` 為套件根目錄、`$2` 為輸出目錄。
    ///
    /// `GIT_OPTIONAL_LOCKS=0` 讓 git 不去碰 index 鎖——建置指令跑在唯讀沙箱裡，
    /// 任何對 `.git` 的寫入都會被擋下。`--always` 讓沒有標籤的淺 checkout（CI 預設）
    /// 回落成短 sha 而非整個失敗。
    ///
    /// 問 git 之前先確認套件根本身就是工作樹（`.git` 存在，用 `-e` 以涵蓋 worktree 的
    /// gitfile 形）：`describe` 會沿目錄往上找，套件被解到別的 repo 底下時會回報外層
    /// repo 的標籤，那個版本號對不上自己、比 `unknown` 更糟。版本字串含 `"` 時（git
    /// 允許的標籤字元）也回落 `unknown`，避免產生檔的字串常值被切斷。
    private static let script: String = """
        set -eu
        package_directory="$1"
        output_directory="$2"
        version=""
        if [ -e "$package_directory/.git" ]; then
            version="$(GIT_OPTIONAL_LOCKS=0 git -C "$package_directory" describe --tags --always 2>/dev/null || true)"
        fi
        case "$version" in *'"'*) version="" ;; esac
        [ -n "$version" ] || version="unknown"
        cat > "$output_directory/LabControllerVersion.swift" <<SWIFT
        //
        //  LabControllerKit
        //
        //  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
        //  Licensed under the Apache License 2.0. See LICENSE for details.
        //
        //  SPDX-License-Identifier: Apache-2.0
        //
        //  本檔由 GenerateVersion plugin 於建置時產生，請勿手動編輯。

        /// 本次建置對應的版本字串。
        public enum LabControllerVersion {

            /// 由 git 標籤推導的版本；無標籤時為短 sha，取不到 git 資訊時為 "unknown"。
            public static let current: String = "$version"
        }
        SWIFT
        """

    /// 對每個目標掛上一道 prebuild 指令，把產生的檔案交回 SwiftPM 一起編譯。
    ///
    /// - Parameters:
    ///   - context: 外掛執行脈絡，用來取得套件根目錄與外掛工作目錄。
    ///   - target: 掛上本外掛的目標。
    /// - Returns: 單一 prebuild 指令。
    internal func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        let outputDirectory: Path = context.pluginWorkDirectory.appending("Generated")
        // build system 會在 prebuild 指令結束後掃描這個目錄收集產物，目錄不存在就中止建置。
        try FileManager.default.createDirectory(
            atPath: outputDirectory.string, withIntermediateDirectories: true
        )
        return [
            .prebuildCommand(
                displayName: "GenerateVersion",
                executable: Path("/bin/sh"),
                arguments: [
                    "-c", Self.script, "generate-version",
                    context.package.directory.string, outputDirectory.string
                ],
                outputFilesDirectory: outputDirectory
            )
        ]
    }
}
