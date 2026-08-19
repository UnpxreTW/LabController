//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

/// 記住「每把事件鑰匙上次送出是什麼時候」的持久層；去重規則要問的那個時刻由這裡回答。
///
/// ``EventDeduplicationPolicy/suppressesEmission(lastEmittedAt:now:)`` 需要一個「上次送出時刻」
/// 才判得出該不該抑制，而那個時刻必須跨行程重啟存活——存在記憶體裡的話，每次重啟都等於宣告
/// 「這件事從沒送過」，於是整批既有事件重發一輪。本型別只負責記住與回答，**不做去重判斷**：
/// 規則在型別表上、判斷在呼叫端，兩者分開才能改規則而不動已存的紀錄。
///
/// **為什麼是 SQLite、而且不加任何依賴**：需要的是「單檔、跨行程有鎖、寫到一半當掉不會壞檔」，
/// 這正是 SQLite 的形狀；而 `SQLite3` 模組由系統 SDK 提供，`import` 即可用，不必為此引入套件。
///
/// **跨實例／跨行程**：同一個檔可以被多個實例或多個行程同時開著——這由 SQLite 自身的檔案鎖
/// 保證，寫入彼此串行、不會互相蓋掉；遇到別人正持有寫鎖時，本型別設定的 busy timeout 讓它等
/// 而不是立刻回 `SQLITE_BUSY`。⚠ 該保證建立在**本機檔案系統**上；資料庫檔放在網路檔案系統
/// （NFS 等）時鎖的行為由該檔案系統決定，不在此保證內。
///
/// **時刻只進不退**：寫入採「取較晚者」——見 ``recordEmissions(_:)``。
public actor EventEmissionStore {

    /// 開著的資料庫連線；生命週期與本實例相同。
    ///
    /// 標 `nonisolated(unsafe)` 是為了 ``deinit`` 收得掉它：連線指標除了 `deinit` 之外只在 actor
    /// 內被碰，而 `deinit` 執行時已經沒有別的參照能同時進來——這個例外由生命週期本身保證，不是
    /// 靠約定。指標型別本身不帶並行保證，故編譯器要求明說。
    private nonisolated(unsafe) let handle: OpaquePointer

    /// 資料庫檔路徑；只用於錯誤訊息。
    private let path: String

    /// 開啟（必要時建立）指定路徑的去重狀態庫。
    ///
    /// 建檔與開檔是同一個呼叫（`SQLITE_OPEN_CREATE`），中間沒有「檔還不在」的窗口。開起來之後
    /// 依序做三件事：設 busy timeout、把檔案權限收成僅擁有者可讀寫、確認結構版本並在空檔上建表。
    ///
    /// - Parameter url: 資料庫檔位置；其上層目錄必須已存在（本型別不建目錄——要建的話得先決定
    ///   建成什麼權限，那是佈署的事、不是狀態庫的事）。
    public init(at url: URL) throws {
        self.path = url.path
        var openedHandle: OpaquePointer?
        let openFlags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult: Int32 = sqlite3_open_v2(path, &openedHandle, openFlags, nil)
        guard openResult == SQLITE_OK, let handle: OpaquePointer = openedHandle else {
            let message: String = Self.message(of: openedHandle)
            // 開失敗時 SQLite 仍可能配置了連線物件（訊息就存在裡面），要自己收掉。
            sqlite3_close_v2(openedHandle)
            throw EventEmissionStoreError.openFailed(path: path, code: openResult, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
        try Self.restrictPermissions(of: url)
        try Self.prepareSchema(on: handle)
    }

    /// 收掉連線。
    ///
    /// **初始化在存好連線之後才失敗時，這裡一樣會跑**——所有屬性都已就位的物件即使 `init` 拋錯，
    /// 語言仍會呼叫 `deinit`（本機 toolchain 實測確認）。因此那些後續步驟不自己補一次關閉：
    /// 補了就是對同一個指標關兩次，第二次讀的是已經還回去的記憶體。
    deinit {
        sqlite3_close_v2(handle)
    }

    /// 查某把鑰匙上次送出的時刻；從沒送過回 `nil`。
    ///
    /// 「查無」是正常路徑、不是錯誤：第一次見到的事件本來就沒有紀錄。
    public func lastEmission(of key: EventKey) throws -> Date? {
        let statement: OpaquePointer = try Self.prepare(Self.selectSQL, on: handle, operation: "select")
        defer { sqlite3_finalize(statement) }
        try Self.bind(key.rawValue, at: 1, of: statement, on: handle, operation: "select")
        let stepResult: Int32 = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            return .init(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        case SQLITE_DONE:
            return nil
        default:
            throw Self.statementError(on: handle, code: stepResult, operation: "select")
        }
    }

    /// 記下某把鑰匙在某個時刻送出過。
    public func recordEmission(of key: EventKey, at date: Date) throws {
        try recordEmissions([key: date])
    }

    /// 一次記下多把鑰匙的送出時刻——整批要嘛全進、要嘛一筆都不進。
    ///
    /// 批次入口存在的理由是**匯入**：既有去重紀錄的一次性遷移是一整批寫入，逐筆各開一次交易會
    /// 讓每筆都付一次 fsync，而中途失敗還會留下「進了一半」的狀態。整批包在一個交易裡，失敗時
    /// 回捲到批次之前。空批次什麼都不做，連交易都不開。
    ///
    /// **同一把鑰匙已有紀錄時取較晚的那個時刻**，不是無條件覆寫。理由是**時刻只進不退**：匯入
    /// 的是舊紀錄、而同一支事件可能在匯入進行中又送出過一次；照時序無條件覆寫會把已經記到的較新
    /// 時刻往回推，抑制窗口於是重新打開、那件事再送一次。「取較晚者」讓寫入順序不影響最終結果。
    public func recordEmissions(_ emissions: [EventKey: Date]) throws {
        guard !emissions.isEmpty else { return }
        try Self.execute("BEGIN IMMEDIATE", on: handle, operation: "begin")
        do {
            let statement: OpaquePointer = try Self.prepare(Self.upsertSQL, on: handle, operation: "upsert")
            defer { sqlite3_finalize(statement) }
            for emission: (key: EventKey, value: Date) in emissions {
                try Self.bind(emission.key.rawValue, at: 1, of: statement, on: handle, operation: "upsert")
                let emittedAt: Double = emission.value.timeIntervalSince1970
                let boundTime: Int32 = sqlite3_bind_double(statement, 2, emittedAt)
                guard boundTime == SQLITE_OK else {
                    throw Self.statementError(on: handle, code: boundTime, operation: "upsert")
                }
                let stepResult: Int32 = sqlite3_step(statement)
                guard stepResult == SQLITE_DONE else {
                    throw Self.statementError(on: handle, code: stepResult, operation: "upsert")
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            // 提交也算在交易裡：它失敗（例如等鎖等到逾時）時交易仍然開著，沒收掉的話這條連線
            // 之後每一次 `BEGIN IMMEDIATE` 都會撞上「交易裡不能再開交易」而全數寫入失敗，而且
            // 那些沒提交的列還會被自己讀成「已經送過」——去重紀錄於是說了謊。
            try Self.execute("COMMIT", on: handle, operation: "commit")
        } catch {
            // 回捲本身再失敗也不改寫原錯誤：先發生的那個才是要查的。
            try? Self.execute("ROLLBACK", on: handle, operation: "rollback")
            throw error
        }
    }

    /// 本型別認得的結構版本；欄位意義一改就跟著改。
    ///
    /// 存在 SQLite 自己的 `user_version` 欄位裡，不另立版本表——它本來就是給這件事用的，而且
    /// 空資料庫的預設值 0 天然表示「還沒建過」。
    ///
    /// 公開是因為**匯入端要對得上**：把既有去重紀錄一次性搬進來的程式在別處，它得看得出手上這個
    /// 檔是哪一版才知道自己寫的欄位意義對不對。
    public static let schemaVersion: Int32 = 1

    /// 等寫鎖的上限；等不到才回 `SQLITE_BUSY`。
    ///
    /// 5 秒是「另一個行程正在寫一批」的量級，而不是「另一個行程掛住了」的量級——後者不該用等的
    /// 蓋過去。輪詢一輪的間隔遠大於此，等待不會積壓。
    private static let busyTimeoutMilliseconds: Int32 = 5000

    /// 資料庫檔權限：僅擁有者可讀寫。
    ///
    /// 內容只有事件鑰匙與時刻、沒有秘密，收窄是縱深防禦不是必要條件。⚠ 只管資料庫檔本身；
    /// SQLite 為交易建立的暫時檔不由本型別開，其權限不在此處控制。
    private static let filePermissions: NSNumber = 0o600

    /// 建表語句。`STRICT` 讓欄位型別在資料庫層被強制，寫進非預期型別當場失敗而不是靜靜存起來。
    private static let createTableSQL: String = """
        CREATE TABLE IF NOT EXISTS event_emissions (
            event_key TEXT PRIMARY KEY NOT NULL,
            last_emitted_at REAL NOT NULL
        ) STRICT
        """

    /// 寫入語句。撞主鍵時取較晚的時刻（見 ``recordEmissions(_:)``）。
    private static let upsertSQL: String = """
        INSERT INTO event_emissions (event_key, last_emitted_at) VALUES (?, ?)
        ON CONFLICT(event_key) DO UPDATE SET
            last_emitted_at = MAX(last_emitted_at, excluded.last_emitted_at)
        """

    /// 查詢語句。
    private static let selectSQL: String = "SELECT last_emitted_at FROM event_emissions WHERE event_key = ?"

    /// 綁定字串時要求 SQLite 自行複製一份。
    ///
    /// **不能用 `SQLITE_STATIC`**：那代表「這塊記憶體我保證活到語句用完」，而 Swift 字串借出的
    /// 緩衝區在呼叫返回後就不保證還在——語句真正執行時讀到的會是已經沒人管的記憶體。
    private static let transientText: sqlite3_destructor_type = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    /// 確認結構版本，並在空資料庫上建表。
    ///
    /// 版本 0 代表這個檔還沒被本型別用過（空檔的預設值）⇒ 建表、蓋上版本號。已是本版就只確保
    /// 表在。其餘一律當場失敗，不猜、不改寫。
    private static func prepareSchema(on handle: OpaquePointer) throws {
        let foundVersion: Int32 = try userVersion(on: handle)
        switch foundVersion {
        case 0:
            try execute(createTableSQL, on: handle, operation: "create table")
            try execute("PRAGMA user_version = \(schemaVersion)", on: handle, operation: "set user_version")
        case schemaVersion:
            try execute(createTableSQL, on: handle, operation: "create table")
        default:
            throw EventEmissionStoreError.unsupportedSchemaVersion(found: foundVersion, expected: schemaVersion)
        }
    }

    /// 讀 `PRAGMA user_version`。沒有回傳列時視為 0（等同空資料庫）。
    private static func userVersion(on handle: OpaquePointer) throws -> Int32 {
        let statement: OpaquePointer = try prepare("PRAGMA user_version", on: handle, operation: "read user_version")
        defer { sqlite3_finalize(statement) }
        let stepResult: Int32 = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0)
        case SQLITE_DONE:
            return 0
        default:
            throw statementError(on: handle, code: stepResult, operation: "read user_version")
        }
    }

    /// 把資料庫檔權限收成僅擁有者可讀寫。
    private static func restrictPermissions(of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
    }

    /// 編譯一句 SQL。
    private static func prepare(
        _ sql: String,
        on handle: OpaquePointer,
        operation: String
    ) throws -> OpaquePointer {
        var preparedStatement: OpaquePointer?
        let prepareResult: Int32 = sqlite3_prepare_v2(handle, sql, -1, &preparedStatement, nil)
        guard prepareResult == SQLITE_OK, let statement: OpaquePointer = preparedStatement else {
            sqlite3_finalize(preparedStatement)
            throw statementError(on: handle, code: prepareResult, operation: operation)
        }
        return statement
    }

    /// 編譯並執行一句不回傳列的 SQL。
    private static func execute(_ sql: String, on handle: OpaquePointer, operation: String) throws {
        let statement: OpaquePointer = try prepare(sql, on: handle, operation: operation)
        defer { sqlite3_finalize(statement) }
        let stepResult: Int32 = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE || stepResult == SQLITE_ROW else {
            throw statementError(on: handle, code: stepResult, operation: operation)
        }
    }

    /// 綁一個字串參數。
    private static func bind(
        _ text: String,
        at index: Int32,
        of statement: OpaquePointer,
        on handle: OpaquePointer,
        operation: String
    ) throws {
        let bindResult: Int32 = sqlite3_bind_text(statement, index, text, -1, transientText)
        guard bindResult == SQLITE_OK else { throw statementError(on: handle, code: bindResult, operation: operation) }
    }

    /// 依當下連線狀態組一則語句錯誤。
    ///
    /// 訊息必須在**這一刻**取——`sqlite3_errmsg` 回的是該連線最近一次失敗的說明，只要對同一個連線
    /// 再呼叫任何一個 API，它就會被下一次結果蓋掉。
    private static func statementError(
        on handle: OpaquePointer,
        code: Int32,
        operation: String
    ) -> EventEmissionStoreError {
        .statementFailed(operation: operation, code: code, message: message(of: handle))
    }

    /// 取連線最近一次失敗的說明。連線根本沒建起來時給一句固定訊息。
    private static func message(of handle: OpaquePointer?) -> String {
        guard let handle: OpaquePointer = handle else { return "no database connection" }
        return .init(cString: sqlite3_errmsg(handle))
    }
}
