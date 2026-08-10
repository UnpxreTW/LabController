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

private final class EventKeyTests {

    /// 偵測時刻；除了測「時刻不進鑰匙」那條以外都用同一個值。
    private let detectedAt: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 同一件事重複偵測到必得同一把鑰匙。
    @Test
    func `the same identity always derives the same key`() throws {
        let first: DetectedEvent = try event(target: .mergeRequest(iid: 7), discriminators: ["abc123"])
        let second: DetectedEvent = try event(target: .mergeRequest(iid: 7), discriminators: ["abc123"])
        #expect(first.key == second.key)
    }

    /// 鑰匙的可讀形狀：型別、專案、目標種類、目標值依序串接。
    @Test
    func `renders identity segments in order`() throws {
        let event: DetectedEvent = try event(
            type: "mr_outdated",
            project: "group/project",
            target: .mergeRequest(iid: 42)
        )
        #expect(event.key.rawValue == "v1|mr_outdated|group/project|merge_request|42")
        #expect(event.key.rawValue.hasPrefix(EventKey.formatVersion + "|"))
        #expect(event.key.description == event.key.rawValue)
    }

    /// 佐證與偵測時刻是佐證、不是身分：兩者不同不影響鑰匙。
    @Test
    func `evidence and detection time stay out of the key`() throws {
        let base: DetectedEvent = try event(target: .issue(iid: 3), inputs: ["labels": "bug"])
        let other: DetectedEvent = .init(
            type: base.type,
            project: base.project,
            target: base.target,
            discriminators: base.discriminators,
            detectedAt: base.detectedAt.addingTimeInterval(3600),
            inputs: ["labels": "bug,urgent", "assignee": "someone"]
        )
        #expect(base.key == other.key)
    }

    /// 目標種類參與身分：同一個號碼落在不同種類上是兩件事。
    @Test
    func `different target kinds with the same number are different events`() throws {
        let mergeRequest: EventKey = try event(target: .mergeRequest(iid: 5)).key
        let issue: EventKey = try event(target: .issue(iid: 5)).key
        let pipeline: EventKey = try event(target: .pipeline(identifier: 5)).key
        let project: EventKey = try event(target: .project).key
        #expect(Set([mergeRequest, issue, pipeline, project]).count == 4)
    }

    /// 區辨段參與身分：換了 commit sha 就是該重新發的另一件事。
    @Test
    func `discriminators participate in identity`() throws {
        let first: EventKey = try event(target: .mergeRequest(iid: 9), discriminators: ["sha-a"]).key
        let second: EventKey = try event(target: .mergeRequest(iid: 9), discriminators: ["sha-b"]).key
        let none: EventKey = try event(target: .mergeRequest(iid: 9)).key
        #expect(Set([first, second, none]).count == 3)
    }

    /// 區辨段的順序算身分的一部分。
    ///
    /// 這條是給偵測端看的：若它從 `Dictionary` 或 `Set` 迭代組出區辨段，順序每輪都可能不同，
    /// 同一件事於是每輪換一把鑰匙、每輪重發，而且沒有任何一處會報錯。
    @Test
    func `discriminator order is part of the identity`() throws {
        let forward: EventKey = try event(discriminators: ["a", "b"]).key
        let reversed: EventKey = try event(discriminators: ["b", "a"]).key
        #expect(forward != reversed)
    }

    /// 段內含分隔字元不得撞鑰匙——直接串接的話這兩件事會被當成同一件而靜靜丟掉一件。
    @Test
    func `a separator inside a segment does not collide with a segment boundary`() throws {
        let joined: DetectedEvent = try event(discriminators: ["x|y"])
        let split: DetectedEvent = try event(discriminators: ["x", "y"])
        #expect(joined.key != split.key)
        #expect(joined.key.rawValue.hasSuffix("|x\\|y"))
        #expect(split.key.rawValue.hasSuffix("|x|y"))
    }

    /// 跳脫字元先轉、分隔字元後轉：順序反過來時這兩件事會撞在一起。
    @Test
    func `escaping the escape character first keeps these two apart`() throws {
        let separatorOnly: EventKey = try event(discriminators: ["|"]).key
        let escapeThenEmpty: EventKey = try event(discriminators: ["\\", ""]).key
        #expect(separatorOnly != escapeThenEmpty)
    }

    /// 專案識別含分隔字元時同樣不與其他段混淆。
    @Test
    func `a separator inside the project identifier stays contained`() throws {
        let odd: EventKey = try event(project: "group|project", target: .project).key
        let plain: EventKey = try event(project: "group", target: .project).key
        #expect(odd != plain)
        #expect(odd.rawValue == "v1|sample_event|group\\|project|project")
    }

    /// 分隔字元後面接一個 combining mark 時仍須轉義——以 grapheme 為單位比對的字串 API
    /// 會漏掉這種，兩件不同的事於是編出同一把鑰匙。
    @Test
    func `a separator inside a multi scalar grapheme is still escaped`() throws {
        let joined: EventKey = try event(discriminators: ["a|\u{0301}b"]).key
        let split: EventKey = try event(discriminators: ["a", "\u{0301}b"]).key
        #expect(joined != split)
    }

    /// 前一段結尾是 Prepend 類字元時同樣不得撞——這類字元會把後面的分隔字元併進同一個
    /// grapheme（阿拉伯文的分支名／標題實際會出現）。
    @Test
    func `a separator absorbed by a preceding prepend scalar is still escaped`() throws {
        let joined: EventKey = try event(discriminators: ["a\u{0600}|b"]).key
        let split: EventKey = try event(discriminators: ["a\u{0600}", "b"]).key
        #expect(joined != split)
    }

    /// 同一段文字的 NFC 與 NFD 兩種寫法得到逐 byte 相同的鑰匙。
    ///
    /// 只靠 `String` 的相等不夠：它是 canonical equivalence，而持久層逐 byte 比——兩者不
    /// 一致時，程式內判定「已發過」的事在資料庫裡會是另一列，於是被送出兩次。
    @Test
    func `canonically equivalent segments derive byte identical keys`() throws {
        let composed: EventKey = try event(project: "caf\u{00E9}").key
        let decomposed: EventKey = try event(project: "cafe\u{0301}").key
        #expect(composed == decomposed)
        #expect(Array(composed.rawValue.utf8) == Array(decomposed.rawValue.utf8))
    }

    /// 區辨段不得冒充目標段：把目標的種類標籤與定位值原樣塞進區辨段，不得與真的那個目標
    /// 撞成同一把鑰匙。
    @Test
    func `discriminators cannot impersonate target segments`() throws {
        let real: EventKey = try event(target: .mergeRequest(iid: 5)).key
        let faked: EventKey = try event(target: .project, discriminators: ["merge_request", "5"]).key
        #expect(real != faked)
    }

    /// 每個種類的代表目標：第一段就是自己的種類標籤，且彼此鑰匙互不相同。
    ///
    /// 標籤字串本身的唯一性由 `Kind` 的 raw value 交給編譯器（重複的 raw value 編不過），
    /// 這裡不重複斷言。這條鎖的是另外兩件編譯器管不到的事：`keySegments` 沒有繞過 `Kind`
    /// 自己寫字串；以及每個種類的代表目標推出來的鑰匙兩兩相異。新增種類時 `representative`
    /// 的窮盡 switch 會逼作者回來面對這兩條。
    @Test
    func `every kind leads with its own tag and yields a distinct key`() throws {
        var keys: Set<EventKey> = []
        for kind: EventTarget.Kind in EventTarget.Kind.allCases {
            let target: EventTarget = Self.representative(of: kind)
            #expect(target.kind == kind, "\(kind)")
            #expect(target.keySegments.first == kind.rawValue, "\(kind)")
            keys.insert(try event(target: target).key)
        }
        #expect(keys.count == EventTarget.Kind.allCases.count)
    }

    /// 自持久層讀回的鑰匙原樣保存，不重新推導。
    @Test
    func `a key read back from storage keeps its raw form`() throws {
        let derived: EventKey = try event(target: .issue(iid: 11)).key
        let restored: EventKey = .init(persisted: derived.rawValue)
        #expect(restored == derived)
    }

    /// 每個種類挑一個代表目標；定位值一律用同一個號碼，好讓「種類本身是否被算進身分」
    /// 成為唯一的差異來源。
    private static func representative(of kind: EventTarget.Kind) -> EventTarget {
        switch kind {
        case .project:
            return .project
        case .mergeRequest:
            return .mergeRequest(iid: 5)
        case .issue:
            return .issue(iid: 5)
        case .pipeline:
            return .pipeline(identifier: 5)
        }
    }

    /// 以預設值組出測試事件；只覆寫關心的那幾欄。
    private func event(
        type rawType: String = "sample_event",
        project: String = "group/project",
        target: EventTarget = .project,
        discriminators: [String] = [],
        inputs: [String: String] = [:]
    ) throws -> DetectedEvent {
        let type: EventType = try #require(EventType(rawValue: rawType))
        return .init(
            type: type,
            project: project,
            target: target,
            discriminators: discriminators,
            detectedAt: detectedAt,
            inputs: inputs
        )
    }
}
