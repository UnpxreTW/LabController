//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一份 ``JobPlan`` 攛成執行環境裡的檔案樹：環境變數檔、檔案型變數、取碼腳本、逐步驟腳本。
///
/// **為什麼是檔案而不是命令列參數**：``ExecutionBackend/exec(_:in:)`` 收的是逐個參數的命令，
/// 而 job 的變數裡有秘密——放進參數列，環境裡任何一個行程都能從行程表上讀到它。攛成檔案之後
/// 秘密只在開機那一刻經注入通道進去（權限 `0o600`、隨環境焚毀），命令列上留下的只有腳本路徑。
///
/// **也不由本側拼 shell 命令列**：payload 的 `steps[].script` 是一行行 shell，而每一行的引號、
/// 換行與變數展開都得原樣送到對面才對得起 CI 檔的作者。自己拼一條長命令等於把跳脫責任攬過來，
/// 而漏跳脫的那一次是把一段內容當成命令執行。
///
/// ⚠️ **本型別的 ``injectedFiles`` 含明文秘密**，理由同 ``JobPlan``：`environment` 與
/// `fileVariables` 的原值都在裡面。不得寫檔、不得印出、不得寫進 trace。
public struct JobWorkspace: Sendable, Equatable {

    /// 本側自用變數的名稱前綴；payload 端的變數不得佔用。
    public static let reservedPrefix: String = "LABCTL_"

    /// 工作根，來自 ``JobRunnerConfiguration/workspaceRoot``。
    public let root: String

    /// 取回的程式碼放在哪；步驟都在這個目錄裡跑。
    public let checkoutDirectory: String

    /// payload 變數檔的路徑；**只有步驟腳本** source 它。
    public let environmentFilePath: String

    /// 取碼座標檔的路徑；**只有取碼腳本** source 它。payload 沒帶 `git_info` 時為 nil。
    ///
    /// **與 payload 變數分成兩份，是為了讓 CI 檔動不了取碼**：取碼跑在 job 自己的任何一行
    /// 之前，它若也載入 payload 變數，一行 `variables: { PATH: /nowhere }` 就能讓取碼失敗，
    /// 而失敗會被歸成「環境錯、可重試」——站台端於是一遍遍重試一件每次都會一樣的事。
    /// 順帶收掉另一件：倉庫網址可能內嵌憑證，分家之後它不再被每個步驟腳本 source 一次。
    public let checkoutEnvironmentFilePath: String?

    /// 取碼腳本的路徑；payload 沒帶 `git_info` 時為 nil（該 job 不需要程式碼）。
    public let checkoutScriptPath: String?

    /// 逐步驟腳本的路徑，**與 ``JobPlan/steps`` 同序、同長度**；照索引取即可。
    public let stepScriptPaths: [String]

    /// 開機時要放進環境的全部檔案。
    public let injectedFiles: [InjectedFile]

    /// 依計劃鋪出檔案樹；名字或座標說不通的當場拋。
    ///
    /// - Parameters:
    ///   - plan: 消化過的 payload。
    ///   - root: 環境內的工作根，須為絕對路徑。
    /// - Throws: ``JobWorkspaceError``；注入檔本身說不通時另拋 ``InjectedFileError``。
    public init(plan: JobPlan, root: String = JobRunnerConfiguration.defaultWorkspaceRoot) throws {
        guard root.hasPrefix("/") else { throw JobWorkspaceError.rootNotAbsolute(root) }
        let checkoutDirectory: String = "\(root)/build"
        let environmentFilePath: String = "\(root)/env.sh"
        var files: [InjectedFile] = []
        var exports: [String] = []
        var seen: Set<String> = []
        // 檔案型變數先鋪：它的環境值是**檔案路徑**而不是內容，站台端的約定即如此，
        // 而路徑要等檔案位置決定之後才寫得出來。
        for variable in plan.fileVariables {
            try Self.validate(name: variable.key, seen: &seen)
            let path: String = "\(root)/files/\(variable.key)"
            files.append(try .init(path: path, contents: .init(variable.value.utf8)))
            exports.append(Self.export(name: variable.key, value: path))
        }
        for variable in plan.environment {
            try Self.validate(name: variable.key, seen: &seen)
            exports.append(Self.export(name: variable.key, value: variable.value))
        }
        var checkoutScriptPath: String?
        var checkoutEnvironmentFilePath: String?
        if let git: GitInfo = plan.git {
            guard !git.hasIncompleteCoordinates else { throw JobWorkspaceError.incompleteGitCoordinates }
            let coordinates: [String] = [
                Self.export(name: "\(Self.reservedPrefix)REPO_URL", value: git.repoURL),
                Self.export(name: "\(Self.reservedPrefix)REF", value: git.ref),
                Self.export(name: "\(Self.reservedPrefix)SHA", value: git.sha),
            ]
            let environmentPath: String = "\(root)/checkout-env.sh"
            files.append(try .init(path: environmentPath,
                                   contents: .init(Self.environmentFile(exports: coordinates).utf8)))
            let path: String = "\(root)/checkout.sh"
            let prelude: String = Self.prelude(sourcing: environmentPath, in: checkoutDirectory, entering: false)
            let script: String = Self.checkoutScript(hasRef: !git.ref.isEmpty, directory: checkoutDirectory)
            files.append(try .init(path: path, contents: .init((prelude + script).utf8)))
            checkoutScriptPath = path
            checkoutEnvironmentFilePath = environmentPath
        }
        var stepScriptPaths: [String] = []
        for (index, step) in plan.steps.enumerated() {
            let path: String = "\(root)/steps/step-\(index).sh"
            // 腳本檔名取索引、不取步驟名：步驟名來自 payload，拿它組路徑等於讓站台端決定
            // 檔案落在哪裡。索引另外保證了與 `stepScriptPaths` 的一一對應。
            let prelude: String = Self.prelude(sourcing: environmentFilePath, in: checkoutDirectory, entering: true)
            let body: String = step.script.joined(separator: "\n")
            files.append(try .init(path: path, contents: .init((prelude + body + "\n").utf8)))
            stepScriptPaths.append(path)
        }
        let environmentFile: String = Self.environmentFile(exports: exports)
        files.insert(try .init(path: environmentFilePath, contents: .init(environmentFile.utf8)), at: 0)
        self.root = root
        self.checkoutDirectory = checkoutDirectory
        self.environmentFilePath = environmentFilePath
        self.checkoutScriptPath = checkoutScriptPath
        self.checkoutEnvironmentFilePath = checkoutEnvironmentFilePath
        self.stepScriptPaths = stepScriptPaths
        self.injectedFiles = files
    }

    /// 環境變數檔的全文。
    private static func environmentFile(exports: [String]) -> String {
        """
        # 由 LabController 產生；內含本次 job 的變數原值，隨執行環境焚毀。
        \(exports.joined(separator: "\n"))

        """
    }

    /// 每個腳本共用的開頭：任一行失敗即停、載入變數、進工作目錄。
    ///
    /// `set -e` 是**必須**而不是保險：少了它，一個步驟裡前面的命令失敗、最後一行卻成功時，
    /// 整個步驟會以零結束——那正是「綠了但事情沒做完」的形狀。
    ///
    /// - Parameter entering: 是否要建立並進入工作目錄；取碼腳本自己要先清掉舊的，故不進。
    private static func prelude(sourcing environmentFile: String, in directory: String, entering: Bool) -> String {
        var lines: [String] = [
            "# 由 LabController 產生；隨執行環境焚毀。",
            "set -e",
            ". \(singleQuoted(environmentFile))",
        ]
        if entering {
            lines.append("mkdir -p \(singleQuoted(directory))")
            lines.append("cd \(singleQuoted(directory))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 取碼腳本的主體。
    ///
    /// **取回的是 sha、不是 ref**：ref 在我們動手的這段時間裡可能又往前走了，照 ref 取會跑到
    /// 一個站台沒有指派給我們的版本上，而結果仍會被回報到原來那個 job 上。ref 只用來把物件抓
    /// 下來（依 sha 直接 fetch 需要站台開特定設定，不能假設它開著）。
    ///
    /// **`--force` 覆蓋本地 ref**：環境雖是一次性的，但這支腳本在同一個環境裡重跑並不違法，
    /// 而非快進的更新在沒有 `--force` 時會被拒絕、症狀是取到舊版本仍照常往下跑。
    ///
    /// **倉庫網址經環境變數進來，本側的 exec 命令列上因此沒有它**：站台慣例會把 job token 放在
    /// 網址的 userinfo 裡，而執行環境裡的行程表是誰都看得到的。⚠️ 收得**不徹底**，兩個破口照實
    /// 寫在這裡：`"$LABCTL_REPO_URL"` 由 shell 展開之後就在 `git` 子行程自己的參數上；`git
    /// remote add` 之後那份網址也會落在取碼目錄的 `.git/config`。兩者都止於這個一次性環境、
    /// 隨焚毀消失；要真的收乾淨得換一種不經參數也不落設定檔的憑證傳遞形，那不是這一片的事。
    ///
    /// ⚠️ 只涵蓋分支與 tag 這種一般 push 形。合併請求的 detached ref 另有形狀（站台把它放在
    /// `refs/merge-requests/<n>/head`，並另外送一組脈絡變數），那是下一片的事、這裡不猜。
    private static func checkoutScript(hasRef: Bool, directory: String) -> String {
        let quoted: String = singleQuoted(directory)
        var lines: [String] = [
            "rm -rf \(quoted)",
            "mkdir -p \(quoted)",
            "cd \(quoted)",
            "git init --quiet",
            "git remote add origin \"$\(reservedPrefix)REPO_URL\"",
        ]
        lines.append(hasRef ? "git fetch --force --quiet origin \"$\(reservedPrefix)REF\""
            : "git fetch --force --quiet origin")
        lines.append("git checkout --quiet --detach \"$\(reservedPrefix)SHA\"")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 一行 `export`；值一律以單引號包起來。
    private static func export(name: String, value: String) -> String {
        "export \(name)=\(singleQuoted(value))"
    }

    /// 把字串包成 shell 的單引號字面。
    ///
    /// 單引號內唯一有特殊意義的字元就是單引號本身，故收掉它即安全：離開引號、送一個跳脫過的
    /// 單引號、再回到引號內。用雙引號的話 `$`、反引號與反斜線都還會被求值，而變數值裡出現
    /// 這些字元完全正常。
    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 變數名必須是合法的 shell 識別字。
    ///
    /// **只收 ASCII**：`Character.isLetter` 涵蓋整個 Unicode 的字母，而 shell 的識別字不是——
    /// 放行一個中日文名的變數，`export` 那一行會在對面變成語法錯誤，於是整個 job 在載入變數
    /// 時就死了，而錯誤訊息裡完全看不出是哪個變數害的。
    /// - Parameter seen: 已經出現過的名字；撞名時拋，因為後寫的 `export` 會靜默蓋掉前一個
    ///   ——一個檔案型變數被同名的一般變數蓋掉時，檔案照樣落地，但腳本讀到的不是它的路徑。
    private static func validate(name: String, seen: inout Set<String>) throws {
        guard !name.hasPrefix(reservedPrefix) else { throw JobWorkspaceError.reservedVariableName(name) }
        guard let first: Character = name.first, first.isASCII, first.isLetter || first == "_" else {
            throw JobWorkspaceError.invalidVariableName(name)
        }
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw JobWorkspaceError.invalidVariableName(name)
        }
        guard seen.insert(name).inserted else { throw JobWorkspaceError.duplicateVariableName(name) }
    }
}
