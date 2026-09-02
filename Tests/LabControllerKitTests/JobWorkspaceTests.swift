//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import Testing

/// 取一份注入檔的內容文字；查無該路徑即測試失敗。
private func contents(of path: String, in workspace: JobWorkspace) throws -> String {
    let file: InjectedFile = try #require(workspace.injectedFiles.first { $0.path == path })
    return .init(decoding: file.contents, as: UTF8.self)
}

private final class JobWorkspaceTests {

    /// 測試共用的工作根。
    private let root: String = "/tmp/labcontroller"

    // MARK: - 變數

    /// 變數逐個寫成 `export`，值以單引號包起來。
    @Test
    func `writes each variable as a quoted export`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            environment: [.init(key: "CI_PROJECT_PATH", value: "group/project")],
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        let text: String = try contents(of: workspace.environmentFilePath, in: workspace)
        #expect(text.contains("export CI_PROJECT_PATH='group/project'"))
    }

    /// 值裡的單引號要跳脫；不跳脫的話那個值會提前收掉引號、後半截變成命令。
    @Test
    func `escapes single quotes inside a variable value`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            environment: [.init(key: "MESSAGE", value: "it's here'; rm -rf /")],
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        let text: String = try contents(of: workspace.environmentFilePath, in: workspace)
        #expect(text.contains("export MESSAGE='it'\\''s here'\\''; rm -rf /'"))
    }

    /// 檔案型變數落成一份檔案，環境裡拿到的是它的路徑。
    @Test
    func `puts a file variable on disk and exports its path`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            fileVariables: [.init(key: "DEPLOY_KEY", value: "key-material", file: true)],
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        #expect(try contents(of: "\(root)/files/DEPLOY_KEY", in: workspace) == "key-material")
        let text: String = try contents(of: workspace.environmentFilePath, in: workspace)
        #expect(text.contains("export DEPLOY_KEY='\(root)/files/DEPLOY_KEY'"))
    }

    /// 注入檔一律關到最緊：裡面裝的是變數原值。
    @Test
    func `keeps every injected file readable only by its owner`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [.init(name: "script", script: ["make"])],
            environment: [.init(key: "TOKEN", value: "secret", masked: true)],
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        #expect(workspace.injectedFiles.allSatisfy { $0.permissions == 0o600 })
    }

    /// 佔用本側前綴的變數名要擋下：被蓋掉的話會取到別的地方去，而 job 仍照常跑完。
    @Test
    func `rejects a variable name that takes the reserved prefix`() {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            environment: [.init(key: "LABCTL_SHA", value: "deadbeef")],
            timeoutSeconds: 60
        )
        #expect(throws: JobWorkspaceError.reservedVariableName("LABCTL_SHA")) {
            try JobWorkspace(plan: plan, root: "/tmp/labcontroller")
        }
    }

    /// 同一個名字出現兩次要擋下：後寫的 export 會靜默蓋掉前一個。
    @Test
    func `rejects the same variable name twice`() {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            environment: [.init(key: "DEPLOY_KEY", value: "literal")],
            fileVariables: [.init(key: "DEPLOY_KEY", value: "key-material", file: true)],
            timeoutSeconds: 60
        )
        #expect(throws: JobWorkspaceError.duplicateVariableName("DEPLOY_KEY")) {
            try JobWorkspace(plan: plan, root: "/tmp/labcontroller")
        }
    }

    /// 不是合法 shell 識別字的變數名要擋下，含非 ASCII 字母。
    @Test
    func `rejects a variable name that is not a shell identifier`() {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            environment: [.init(key: "專案路徑", value: "group/project")],
            timeoutSeconds: 60
        )
        #expect(throws: JobWorkspaceError.invalidVariableName("專案路徑")) {
            try JobWorkspace(plan: plan, root: "/tmp/labcontroller")
        }
    }

    // MARK: - 取碼

    /// 取碼靠 ref 把物件抓下來、靠 sha 決定停在哪個版本。
    @Test
    func `fetches by ref and checks out the exact commit`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            git: .init(repoURL: "https://gitlab.example/group/project.git", ref: "main", sha: "deadbeef"),
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        let path: String = try #require(workspace.checkoutScriptPath)
        let script: String = try contents(of: path, in: workspace)
        #expect(script.contains("git fetch --force --quiet origin \"$LABCTL_REF\""))
        #expect(script.contains("git checkout --quiet --detach \"$LABCTL_SHA\""))
    }

    /// 站台指定了 refspec 就照它抓：合併請求要跑的 commit 照 ref 抓不到。
    @Test
    func `fetches by the refspecs the site specified`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            git: .init(
                repoURL: "https://gitlab.example/group/project.git",
                ref: "main",
                sha: "deadbeef",
                refspecs: [
                    "+refs/merge-requests/7/head:refs/remotes/origin/merge-requests/7/head",
                    "+refs/heads/main:refs/remotes/origin/main",
                ]
            ),
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        let path: String = try #require(workspace.checkoutScriptPath)
        let script: String = try contents(of: path, in: workspace)
        let checkoutEnvironment: String = try #require(workspace.checkoutEnvironmentFilePath)
        let environment: String = try contents(of: checkoutEnvironment, in: workspace)
        #expect(script.contains("git fetch --force --quiet origin \"$LABCTL_REFSPEC_0\" \"$LABCTL_REFSPEC_1\""))
        #expect(script.contains("\"$LABCTL_REF\"") == false)
        #expect(script.contains("git checkout --quiet --detach \"$LABCTL_SHA\""))
        #expect(environment.contains(
            "export LABCTL_REFSPEC_0='+refs/merge-requests/7/head:refs/remotes/origin/merge-requests/7/head'"
        ))
        #expect(environment.contains("export LABCTL_REFSPEC_1='+refs/heads/main:refs/remotes/origin/main'"))
    }

    /// refspec 的內容不進命令列本文：它是 payload 值，與其他座標同一條規則。
    @Test
    func `keeps refspec values out of the script body`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            git: .init(repoURL: "https://gitlab.example/group/project.git", ref: "main", sha: "deadbeef",
                       refspecs: ["+refs/merge-requests/7/head:refs/remotes/origin/merge-requests/7/head"]),
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        let path: String = try #require(workspace.checkoutScriptPath)
        let script: String = try contents(of: path, in: workspace)
        #expect(script.contains("merge-requests") == false)
    }

    /// 倉庫網址走環境變數、不進命令列：命令列在環境裡是誰都看得到的。
    @Test
    func `keeps the repository URL out of the command line`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            git: .init(repoURL: "https://user:token@gitlab.example/group/project.git", ref: "main", sha: "deadbeef"),
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        let path: String = try #require(workspace.checkoutScriptPath)
        let script: String = try contents(of: path, in: workspace)
        #expect(script.contains("git remote add origin \"$LABCTL_REPO_URL\""))
        #expect(script.contains("token") == false)
    }

    /// 取碼載入的是取碼座標那一份、不是 payload 變數：CI 檔因此動不了取碼這一步。
    @Test
    func `keeps payload variables out of the checkout script`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            git: .init(repoURL: "https://gitlab.example/group/project.git", ref: "main", sha: "deadbeef"),
            environment: [.init(key: "PATH", value: "/nonexistent")],
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        let checkoutEnvironment: String = try #require(workspace.checkoutEnvironmentFilePath)
        let path: String = try #require(workspace.checkoutScriptPath)
        let script: String = try contents(of: path, in: workspace)
        #expect(script.contains(". '\(checkoutEnvironment)'"))
        #expect(script.contains(workspace.environmentFilePath) == false)
        #expect(try contents(of: checkoutEnvironment, in: workspace).contains("PATH") == false)
    }

    /// 座標不全的 `git_info` 要當場擋下，不留給執行階段去炸。
    @Test
    func `rejects git info without the coordinates a checkout needs`() {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            git: .init(repoURL: "https://gitlab.example/group/project.git", ref: "main", sha: ""),
            timeoutSeconds: 60
        )
        #expect(throws: JobWorkspaceError.incompleteGitCoordinates) {
            try JobWorkspace(plan: plan, root: "/tmp/labcontroller")
        }
    }

    /// payload 沒帶 `git_info` 的 job 不需要取碼，也就沒有取碼腳本。
    @Test
    func `skips the checkout script when the payload carries no git info`() throws {
        let plan: JobPlan = .init(jobIdentifier: 1, steps: [.init(name: "script", script: ["echo hi"])],
                                  timeoutSeconds: 60)
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        #expect(workspace.checkoutScriptPath == nil)
    }

    // MARK: - 步驟

    /// 步驟腳本與步驟一一對應，且原樣帶著 CI 檔那幾行。
    @Test
    func `renders one script per step in payload order`() throws {
        let plan: JobPlan = .init(
            jobIdentifier: 1,
            steps: [
                .init(name: "script", script: ["swift build", "swift test"]),
                .init(name: "after_script", script: ["cleanup"], runCondition: .always),
            ],
            timeoutSeconds: 60
        )
        let workspace: JobWorkspace = try .init(plan: plan, root: root)
        #expect(workspace.stepScriptPaths == ["\(root)/steps/step-0.sh", "\(root)/steps/step-1.sh"])
        let first: String = try contents(of: workspace.stepScriptPaths[0], in: workspace)
        #expect(first.contains("swift build\nswift test"))
        #expect(first.contains("set -e"))
        #expect(first.contains(". '\(root)/env.sh'"))
        #expect(first.contains("cd '\(root)/build'"))
    }

    /// 工作根必須是絕對路徑；相對於誰本側答不出來。
    @Test
    func `rejects a workspace root that is not absolute`() {
        let plan: JobPlan = .init(jobIdentifier: 1, timeoutSeconds: 60)
        #expect(throws: JobWorkspaceError.rootNotAbsolute("labcontroller")) {
            try JobWorkspace(plan: plan, root: "labcontroller")
        }
    }
}
