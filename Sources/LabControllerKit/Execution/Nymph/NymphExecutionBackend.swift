//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 以 nymph daemon 開出來的一次性虛擬機當執行環境，``ExecutionBackend`` 的第一個實作。
///
/// **接的是 daemon 的 socket 協議，不是它的函式庫**：把對面當套件引進來，本專案的建置就跟著
/// 它的版本走，而本側真正要的只是「一行請求換一行回應」。線上的形狀鏡在 ``NymphRequest`` 與
/// ``NymphResponse``，由測試以逐字 JSON 釘住。
///
/// **這一層只做翻譯**：本側協議的五個動作對到對面的五個動詞，幾乎一比一——真正要寫的是兩件
/// 事之間對不上的地方，也就是下面幾條。
///
/// - 對面的 `spawn` 只認基底別名，本側的 ``GuestImage/path(_:)`` 在線上沒有對應欄位，只能
///   當面拒絕（見 ``spawn(_:)``）。
/// - 對面沒有「開機時放檔案進去」這個概念，本側的注入檔改成開機之後逐份寫進去。
/// - 對面回的兩道輸出已經是文字，本側的 ``CommandResult`` 收位元組——中間過了一次解碼，要
///   逐 byte 比對的東西走不了這條路。
public struct NymphExecutionBackend: ExecutionBackend {

    // MARK: Public

    /// 建立。
    ///
    /// - Parameters:
    ///   - transport: 與 daemon 之間的線。
    ///   - configuration: 開 guest 用的參數。
    ///   - now: 取當下時刻；測試注入固定時鐘。對面只回「開了幾秒」，本側協議要的是開機時刻，
    ///     換算需要一個當下（見 ``ps()``）。
    public init(
        transport: any NymphTransport,
        configuration: NymphBackendConfiguration,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.configuration = configuration
        self.now = now
    }

    /// 開一台 guest、等到可以收命令，再把注入檔逐份寫進去。
    ///
    /// **沒開成的那台在這裡就清掉**：識別碼還沒交到呼叫端手上，這裡不清就沒有人清得到——它會
    /// 一直佔著併發額度，而唯一看得到它的地方是 ``ps()``。清除失敗不覆蓋原本的錯：呼叫端當下
    /// 要看的是「為什麼沒開成」。
    ///
    /// - Parameter specification: 基底與注入檔。
    /// - Returns: 新 guest 的識別碼。
    /// - Throws: ``ExecutionBackendError``。
    public func spawn(_ specification: GuestSpecification) async throws -> GuestIdentifier {
        guard case let .alias(golden) = specification.image else {
            throw ExecutionBackendError.requestRejected(
                detail: "nymph 只認基底別名，主機路徑在這個後端沒有對應的請求欄位"
            )
        }
        let response: NymphResponse = try await exchange(.spawn(.init(
            golden: golden,
            os: configuration.os,
            cpus: configuration.cpus,
            memoryGiB: configuration.memoryGiB,
            wait: true,
            readinessTimeoutSeconds: configuration.readinessTimeoutSeconds
        )))
        guard case let .spawn(result) = response else { throw Self.unexpected(response, verb: "spawn", guest: nil) }
        let guest: GuestIdentifier = .init(result.id)
        guard result.state == .ready else {
            try? await destroy(guest)
            throw ExecutionBackendError.guestNotReady(guest, state: Self.guestState(from: result.state))
        }
        do {
            try await inject(specification.injectedFiles, into: guest)
        } catch {
            try? await destroy(guest)
            throw error
        }
        return guest
    }

    /// 在指定 guest 裡跑一道命令。
    ///
    /// **不下逾時**：整件工作的掛鐘預算由呼叫端那一層管（見 ``JobTimeoutPolicy``），兩層各設一
    /// 個上限時，先到的那一個會把另一個的語義蓋掉，而排查時看到的只是「不知道被誰砍掉了」。
    ///
    /// - Parameters:
    ///   - command: 可執行檔與其參數。
    ///   - guest: 在哪台裡跑。
    /// - Returns: 結束碼與兩道輸出。
    /// - Throws: ``ExecutionBackendError``。
    public func exec(_ command: [String], in guest: GuestIdentifier) async throws -> CommandResult {
        try await execute(command, standardInput: nil, in: guest)
    }

    /// 對面當下有哪些 guest，含已停止的。
    ///
    /// **連停掉的一起要**：本側協議的 ``GuestState/stopped`` 是一種還佔著資源的狀態，回收孤兒
    /// 的人正是靠它看到「這台還在、但沒人管了」。只列活著的等於把要回收的那些藏起來。
    ///
    /// - Returns: 各 guest 的當下樣子。
    /// - Throws: ``ExecutionBackendError``。
    public func ps() async throws -> [GuestSummary] {
        let response: NymphResponse = try await exchange(.list(.init(all: true)))
        guard case let .list(result) = response else { throw Self.unexpected(response, verb: "list", guest: nil) }
        return result.sessions.map(summary(from:))
    }

    /// 查單一 guest。
    ///
    /// - Parameter guest: 識別碼。
    /// - Returns: 當下樣子。
    /// - Throws: 查無此 guest 時 ``ExecutionBackendError/unknownGuest(_:)``；其餘見
    ///   ``ExecutionBackendError``。
    public func status(of guest: GuestIdentifier) async throws -> GuestSummary {
        let response: NymphResponse = try await exchange(.status(.init(id: guest.rawValue)))
        guard case let .status(result) = response else { throw Self.unexpected(response, verb: "status", guest: guest) }
        return summary(from: result.summary)
    }

    /// 清掉一台 guest。
    ///
    /// **查無此 guest 當成功**：本側協議要求焚毀是幂等的，而對面把「沒有這個 id」回成錯誤——
    /// 兩者的差就在這一行吃掉。收拾路徑常被走兩次，而第二次要的正是「已經沒有了」。
    ///
    /// - Parameter guest: 識別碼。
    /// - Throws: ``ExecutionBackendError``。
    public func destroy(_ guest: GuestIdentifier) async throws {
        let response: NymphResponse = try await exchange(.destroy(.init(id: guest.rawValue, force: true)))
        if case let .toolError(error) = response, error.code == Self.noSuchIdentifierCode { return }
        guard case .destroy = response else { throw Self.unexpected(response, verb: "destroy", guest: guest) }
    }

    // MARK: Private

    /// 把注入檔寫進 guest 的命令；路徑與權限走位置參數，不拼進字串。
    ///
    /// **內容走 base64、不直接餵原文**：對面的標準輸入欄位是 JSON 字串，塞不進不是 UTF-8 的
    /// 位元組，而注入的內容是任意 ``Data``。解碼旗標取 `-d`——macOS 另有 `-D`，但 `-d` 是兩種
    /// guest 都認的那一個。
    ///
    /// **路徑用 `"$1"`、權限用 `"$2"`**：把它們插進命令字串等於讓每一個帶空白或引號的路徑各自
    /// 需要一次跳脫，而漏掉的那一次是把一段內容當成命令執行。`umask` 先關緊，權限在檔案存在
    /// 之後才由 `chmod` 定到指定值——中間那一小段時間不會有一份權限比要求寬的憑證躺在那裡。
    private static let injectionScript: String = """
        set -e
        umask 077
        mkdir -p "$(dirname "$1")"
        base64 -d > "$1"
        chmod "$2" "$1"
        """

    /// 對面用來表示「沒有這個 id」的錯誤碼。
    ///
    /// 單獨取名的理由是它出現在兩個語義相反的地方：查詢時是「查無此 guest」，清除時卻正是想要
    /// 的結果。字面值散在兩處時，改掉其中一處而漏掉另一處不會有任何徵兆。
    private static let noSuchIdentifierCode: String = "no_such_id"

    /// 與 daemon 之間的線。
    private let transport: any NymphTransport

    /// 開 guest 用的參數。
    private let configuration: NymphBackendConfiguration

    /// 取當下時刻。
    private let now: @Sendable () -> Date

    /// 把對面的狀態翻成本側協議的狀態。
    ///
    /// `idle` 與 `booting` 都收斂成 ``GuestState/starting``：本側協議只問「能不能收命令了」，
    /// 而這兩者的答案都是還不能。
    private static func guestState(from state: NymphSessionState) -> GuestState {
        switch state {
        case .idle, .booting:
            return .starting

        case .ready:
            return .running

        case .stopped:
            return .stopped
        }
    }

    /// 回應的種類與送出的動詞對不上——這不是工具層的失敗，是這條線上出了不該有的東西。
    private static func unexpected(
        _ response: NymphResponse,
        verb: String,
        guest: GuestIdentifier?
    ) -> ExecutionBackendError {
        if case let .toolError(error) = response {
            return failure(error, guest: guest)
        }
        return .backendUnavailable(detail: "\(verb) 收到對不上的回應")
    }

    /// 把對面的工具層失敗翻成本側的錯誤。
    ///
    /// **判別只看 `code`**：那是對面承諾穩定的一半，`message` 是給人看的脈絡。分派的原則是
    /// 「重開一台會不會有用」——會的（還沒就緒、連不上）與不會的（別名不存在、額度滿了）走不同
    /// 的 case，因為呼叫端拿它們做的事不一樣。
    private static func failure(_ error: NymphResponse.ToolError, guest: GuestIdentifier?) -> ExecutionBackendError {
        // 下面兩則都是在講某一台 guest。沒有對象可講時（`spawn`／`list` 本就不指定對象）它們不
        // 該出現，硬湊一個識別碼出來只會讓呼叫端拿著一個不存在的東西往下走，故留給後面兩條。
        if let guest {
            switch error.code {
            case Self.noSuchIdentifierCode:
                return .unknownGuest(guest)

            case "not_ready":
                // 對面這則不帶狀態，本側取「還沒到能收命令的程度」——它涵蓋的正是這一則會出現
                // 的那段期間。要更準就得多問一次 status，而那一次問到的也已經是下一刻的答案。
                return .guestNotReady(guest, state: .starting)

            default:
                break
            }
        }
        switch error.code {
        case "admission_denied", "golden_not_found", "clone_failed", "engine_unavailable", "not_apple_silicon":
            return .requestRejected(detail: "\(error.code)：\(error.message)")

        default:
            // 含 `transport_failure`／`timed_out`／`ip_unavailable`／`internal_error`，以及對面
            // 之後才加的碼：本側沒有更好的處置，一律當成「這個後端當下用不了」，`detail` 留在
            // 日誌裡供排查。認不得就往這裡收，總比認錯成「這台不存在」而讓呼叫端把它從表上劃掉。
            return .backendUnavailable(detail: "\(error.code)：\(error.message)")
        }
    }

    /// 送一則請求、收一則回應；編碼、傳輸、解碼三段的失敗都收成後端用不了。
    private func exchange(_ request: NymphRequest) async throws -> NymphResponse {
        let requestLine: Data
        do {
            requestLine = try JSONEncoder().encode(request)
        } catch {
            throw ExecutionBackendError.backendUnavailable(detail: "請求編不出來：\(error)")
        }
        let responseLine: Data
        do {
            responseLine = try await transport.exchange(requestLine)
        } catch {
            throw ExecutionBackendError.backendUnavailable(detail: "\(error)")
        }
        do {
            return try JSONDecoder().decode(NymphResponse.self, from: responseLine)
        } catch {
            // 回應原文不進錯誤訊息：它可能帶著 guest 的輸出，而這則錯誤會被往上帶。
            throw ExecutionBackendError.backendUnavailable(detail: "回應讀不懂：\(error)")
        }
    }

    /// 跑一道命令，可帶標準輸入。
    private func execute(
        _ command: [String],
        standardInput: String?,
        in guest: GuestIdentifier
    ) async throws -> CommandResult {
        let response: NymphResponse = try await exchange(.execute(.init(
            id: guest.rawValue,
            command: command,
            timeoutSeconds: nil,
            standardInput: standardInput,
            workingDirectory: nil,
            environment: [:]
        )))
        guard case let .execute(result) = response else {
            throw Self.unexpected(response, verb: "execute", guest: guest)
        }
        return .init(
            command: command,
            exitCode: result.exit,
            standardOutput: .init(result.standardOutput.utf8),
            standardError: .init(result.standardError.utf8)
        )
    }

    /// 把注入檔逐份寫進 guest。
    ///
    /// **寫失敗只帶路徑與結束碼**：這條路徑上流過的是憑證，而命令的兩道輸出很可能把寫不進去的
    /// 那份內容原樣印出來——錯誤訊息會被往上帶、也會進日誌。
    private func inject(_ files: [InjectedFile], into guest: GuestIdentifier) async throws {
        for file in files {
            let result: CommandResult = try await execute(
                ["/bin/sh", "-c", Self.injectionScript, "sh", file.path, String(file.permissions, radix: 8)],
                standardInput: file.contents.base64EncodedString(),
                in: guest
            )
            guard result.isSuccess else {
                throw ExecutionBackendError.requestRejected(
                    detail: "注入檔寫不進去：\(file.path)（結束碼 \(result.exitCode)）"
                )
            }
        }
    }

    /// 把對面的 guest 摘要翻成本側協議的摘要。
    ///
    /// **開機時刻是回推出來的**：對面只說「開了幾秒」，本側協議要的是時刻，於是以當下往回減。
    /// 這個值因此帶著一次網路往返的誤差——它的用途是看「這台開多久了」，秒級誤差不影響；要拿它
    /// 當時序基準的地方另想辦法。
    private func summary(from wire: NymphResponse.SessionSummary) -> GuestSummary {
        .init(
            identifier: .init(wire.id),
            image: .alias(wire.golden),
            state: Self.guestState(from: wire.state),
            startedAt: now().addingTimeInterval(-Double(wire.uptimeSeconds))
        )
    }
}
