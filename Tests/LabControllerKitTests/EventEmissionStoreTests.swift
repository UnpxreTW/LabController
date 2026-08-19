//
//  LabControllerKitTests
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import LabControllerKit
import SQLite3
import Testing

private final class EventEmissionStoreTests {

    /// 本次測試的暫存目錄；每個實例一個，測試之間不共用檔案。
    private let directory: URL

    /// 基準時刻；需要「較早／較晚」時以此加減。
    private let now: Date = .init(timeIntervalSince1970: 1_800_000_000.5)

    /// 建暫存目錄。
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventEmissionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 收掉暫存目錄；清不掉也不讓測試失敗（清理失敗不是被測行為）。
    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 沒送過的鑰匙查回 `nil`——查無是正常路徑、不是錯誤。
    @Test
    func `reports no emission for a key never seen`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        #expect(try await store.lastEmission(of: key(target: .issue(iid: 1))) == nil)
    }

    /// 記下的時刻查得回來，且不被四捨五入成整秒。
    @Test
    func `reads back the recorded time including its fraction`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let target: EventKey = key(target: .mergeRequest(iid: 7))
        try await store.recordEmission(of: target, at: now)
        let readBack: Date = try #require(try await store.lastEmission(of: target))
        #expect(readBack.timeIntervalSince1970 == now.timeIntervalSince1970)
    }

    /// 不同鑰匙各記各的，互不影響。
    @Test
    func `keeps one time per key`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let first: EventKey = key(target: .issue(iid: 1))
        let second: EventKey = key(target: .issue(iid: 2))
        try await store.recordEmission(of: first, at: now)
        try await store.recordEmission(of: second, at: now.addingTimeInterval(60))
        #expect(try await store.lastEmission(of: first) == now)
        #expect(try await store.lastEmission(of: second) == now.addingTimeInterval(60))
    }

    /// 較晚的時刻蓋得過較早的。
    @Test
    func `advances the time when a later emission is recorded`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let target: EventKey = key(target: .project)
        try await store.recordEmission(of: target, at: now)
        try await store.recordEmission(of: target, at: now.addingTimeInterval(300))
        #expect(try await store.lastEmission(of: target) == now.addingTimeInterval(300))
    }

    /// 較早的時刻推不回去——寫入順序不影響最終結果。
    ///
    /// 這條釘住的是匯入情境：匯入舊紀錄時同一支事件可能剛送出過，無條件覆寫會把抑制窗口
    /// 重新打開、那件事再送一次。
    @Test
    func `never moves the time backwards`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let target: EventKey = key(target: .project)
        try await store.recordEmission(of: target, at: now)
        try await store.recordEmission(of: target, at: now.addingTimeInterval(-300))
        #expect(try await store.lastEmission(of: target) == now)
    }

    /// 一批多筆一次寫進去。
    @Test
    func `records a whole batch`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        let first: EventKey = key(target: .issue(iid: 3))
        let second: EventKey = key(target: .mergeRequest(iid: 4))
        try await store.recordEmissions([first: now, second: now.addingTimeInterval(1)])
        #expect(try await store.lastEmission(of: first) == now)
        #expect(try await store.lastEmission(of: second) == now.addingTimeInterval(1))
    }

    /// 空批次不是錯誤、也不留下任何一列。
    @Test
    func `writes nothing for an empty batch`() async throws {
        let store: EventEmissionStore = try .init(at: databaseURL())
        try await store.recordEmissions([:])
        #expect(try await store.lastEmission(of: key(target: .project)) == nil)
    }

    /// 紀錄跨行程存活：關掉再開同一個檔，先前記的時刻還在。
    ///
    /// 這是本型別存在的理由本身——存在記憶體裡的話，重啟等於宣告「這件事從沒送過」。
    @Test
    func `keeps records across reopening the same file`() async throws {
        let url: URL = databaseURL()
        let target: EventKey = key(target: .pipeline(identifier: 9))
        var store: EventEmissionStore? = try EventEmissionStore(at: url)
        try await #require(store).recordEmission(of: target, at: now)
        store = nil
        let reopened: EventEmissionStore = try .init(at: url)
        #expect(try await reopened.lastEmission(of: target) == now)
    }

    /// 同一個檔開兩個實例：一邊寫、另一邊看得到，且不會把對方的紀錄清掉。
    @Test
    func `sees records written through another instance of the same file`() async throws {
        let url: URL = databaseURL()
        let reader: EventEmissionStore = try .init(at: url)
        let writer: EventEmissionStore = try .init(at: url)
        let existing: EventKey = key(target: .issue(iid: 5))
        try await reader.recordEmission(of: existing, at: now)
        let written: EventKey = key(target: .issue(iid: 6))
        try await writer.recordEmission(of: written, at: now.addingTimeInterval(30))
        #expect(try await reader.lastEmission(of: written) == now.addingTimeInterval(30))
        #expect(try await writer.lastEmission(of: existing) == now)
    }

    /// 資料庫檔建成僅擁有者可讀寫。
    @Test
    func `creates the database file readable only by its owner`() async throws {
        let url: URL = databaseURL()
        let store: EventEmissionStore = try .init(at: url)
        try await store.recordEmission(of: key(target: .project), at: now)
        let attributes: [FileAttributeKey: Any] = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions: NSNumber = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600)
    }

    /// 認不得的結構版本當場失敗，不照舊讀寫。
    @Test
    func `refuses a database written by an unknown schema version`() async throws {
        let url: URL = databaseURL()
        _ = try EventEmissionStore(at: url)
        try setUserVersion(99, at: url)
        do {
            _ = try EventEmissionStore(at: url)
            Issue.record("認不得的結構版本應該當場失敗")
        } catch let error as EventEmissionStoreError {
            #expect(error == .unsupportedSchemaVersion(found: 99, expected: EventEmissionStore.schemaVersion))
        }
    }

    /// 開不起來時帶著路徑與 SQLite 的說法拋出，不是靜靜回一個空的狀態庫。
    @Test
    func `fails loudly when the database cannot be opened`() async throws {
        let url: URL = directory.appendingPathComponent("missing-directory/emissions.sqlite3")
        do {
            _ = try EventEmissionStore(at: url)
            Issue.record("上層目錄不存在時應該開不起來")
        } catch let error as EventEmissionStoreError {
            guard case let .openFailed(path: path, code: code, message: message) = error else {
                Issue.record("預期 openFailed，實得 \(error)")
                return
            }
            #expect(path == url.path)
            #expect(code != SQLITE_OK)
            #expect(!message.isEmpty)
        }
    }

    /// 本次測試獨用的資料庫檔位置。
    private func databaseURL() -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).sqlite3")
    }

    /// 以事件推導一把鑰匙；只覆寫關心的那一欄。
    private func key(target: EventTarget) -> EventKey {
        guard let type: EventType = EventType(rawValue: "sample_event") else { preconditionFailure("固定字面值必為合法事件型別") }
        let event: DetectedEvent = .init(type: type, project: "group/project", target: target, detectedAt: now)
        return event.key
    }

    /// 繞過本型別、直接改資料庫檔的結構版本；只給版本不合的測試用。
    private func setUserVersion(_ version: Int32, at url: URL) throws {
        var handle: OpaquePointer?
        let openResult: Int32 = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close_v2(handle) }
        try #require(openResult == SQLITE_OK)
        try #require(sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK)
    }
}
