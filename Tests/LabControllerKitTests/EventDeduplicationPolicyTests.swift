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

private final class EventDeduplicationPolicyTests {

    /// 判定基準時刻；測試全用固定時刻、不取系統時鐘。
    private let now: Date = .init(timeIntervalSince1970: 1_800_000_000)

    /// 從未發過就不抑制，無論何種政策。
    @Test
    func `never emitted is never suppressed`() {
        #expect(EventDeduplicationPolicy.permanent.suppressesEmission(lastEmittedAt: nil, now: now) == false)
        #expect(EventDeduplicationPolicy.window(seconds: 300).suppressesEmission(lastEmittedAt: nil, now: now) == false)
    }

    /// permanent：發過一次之後，隔多久都不再發。
    @Test
    func `permanent suppresses forever after the first emission`() {
        let policy: EventDeduplicationPolicy = .permanent
        #expect(policy.suppressesEmission(lastEmittedAt: now.addingTimeInterval(-1), now: now))
        #expect(policy.suppressesEmission(lastEmittedAt: now.addingTimeInterval(-86_400 * 365), now: now))
    }

    /// window：窗內抑制、剛好到期即放行（邊界為左閉右開）。
    @Test
    func `window suppresses inside the window and releases at the boundary`() {
        let policy: EventDeduplicationPolicy = .window(seconds: 300)
        #expect(policy.suppressesEmission(lastEmittedAt: now.addingTimeInterval(-299), now: now))
        #expect(policy.suppressesEmission(lastEmittedAt: now.addingTimeInterval(-300), now: now) == false)
        #expect(policy.suppressesEmission(lastEmittedAt: now.addingTimeInterval(-301), now: now) == false)
    }

    /// 零秒窗等同不抑制——包含上次發送時刻落在此刻之後那一段（別台機器時鐘快一點點時，
    /// 「完全不抑制」的設定不該突然開始抑制）。
    @Test
    func `a zero second window suppresses nothing`() {
        let policy: EventDeduplicationPolicy = .window(seconds: 0)
        #expect(policy.suppressesEmission(lastEmittedAt: now, now: now) == false)
        #expect(policy.suppressesEmission(lastEmittedAt: now.addingTimeInterval(-0.001), now: now) == false)
        #expect(policy.suppressesEmission(lastEmittedAt: now.addingTimeInterval(0.001), now: now) == false)
        #expect(policy.suppressesEmission(lastEmittedAt: now.addingTimeInterval(3600), now: now) == false)
    }

    /// 時鐘回跳（上次發送時刻落在此刻之後）在有窗的政策下判抑制，而不是把整批事件重發一遍。
    @Test
    func `a backwards clock jump suppresses instead of reemitting`() {
        let future: Date = now.addingTimeInterval(3600)
        #expect(EventDeduplicationPolicy.window(seconds: 300).suppressesEmission(lastEmittedAt: future, now: now))
        #expect(EventDeduplicationPolicy.window(seconds: 1).suppressesEmission(lastEmittedAt: future, now: now))
        #expect(EventDeduplicationPolicy.permanent.suppressesEmission(lastEmittedAt: future, now: now))
    }

    /// 兩種政策的組態形狀都解得回來。
    @Test
    func `decodes both policy shapes`() throws {
        let decoder: JSONDecoder = .init()
        let permanent: EventDeduplicationPolicy = try decoder.decode(
            EventDeduplicationPolicy.self,
            from: .init(#"{"mode":"permanent"}"#.utf8)
        )
        #expect(permanent == .permanent)
        let window: EventDeduplicationPolicy = try decoder.decode(
            EventDeduplicationPolicy.self,
            from: .init(#"{"mode":"window","seconds":300}"#.utf8)
        )
        #expect(window == .window(seconds: 300))
    }

    /// 未知政策名不猜意圖、直接失敗。
    @Test
    func `decoding rejects an unknown mode`() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventDeduplicationPolicy.self, from: .init(#"{"mode":"forever"}"#.utf8))
        }
    }

    /// 負秒數的窗沒有意義，視為組態錯誤。
    @Test
    func `decoding rejects a negative window`() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                EventDeduplicationPolicy.self,
                from: .init(#"{"mode":"window","seconds":-1}"#.utf8)
            )
        }
    }

    /// window 缺 `seconds` 欄即失敗，不回落成某個預設窗。
    @Test
    func `decoding rejects a window without seconds`() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventDeduplicationPolicy.self, from: .init(#"{"mode":"window"}"#.utf8))
        }
    }

    /// 窗秒數不是非負整數時，錯誤必須指到 `seconds` 這一欄並說得出原因。
    ///
    /// 直接解成整數型別做不到：`JSONDecoder` 對「數字放不進目標整數型別」是在掃描階段就
    /// 失敗，回一句「不是合法 JSON」、`codingPath` 為空，十筆定義裡哪一筆寫錯完全看不出來。
    @Test
    func `an out of range window points at the seconds field`() throws {
        let bodies: [String] = [
            #"{"mode":"window","seconds":-1}"#,
            #"{"mode":"window","seconds":1e30}"#,
            #"{"mode":"window","seconds":300.5}"#,
            #"{"mode":"window","seconds":1e128}"#
        ]
        for body: String in bodies {
            do {
                _ = try JSONDecoder().decode(EventDeduplicationPolicy.self, from: .init(body.utf8))
                Issue.record("應該解不出來：\(body)")
            } catch let DecodingError.dataCorrupted(context) {
                #expect(context.codingPath.map(\.stringValue) == ["seconds"], "\(body)")
                #expect(context.debugDescription.contains("整數"), "\(body)")
            }
        }
    }

    /// 完全讀不出數值時，訊息不得替作者猜原因。
    ///
    /// 「遠超出可表示範圍」（`1e400`）與「字面值本身寫壞」（`01`、`1.2.3`）在這一層讀起來
    /// 一模一樣——兩邊都拿不到數值。斷言其中一種就會把作者推去查錯的地方：叫寫 `1e400` 的人
    /// 去找前導零，或叫寫 `01` 的人去把值改小，兩種都找不到東西。
    @Test
    func `a value with no readable number does not guess the cause`() throws {
        let bodies: [String] = [
            #"{"mode":"window","seconds":01}"#,
            #"{"mode":"window","seconds":1.2.3}"#,
            #"{"mode":"window","seconds":1e400}"#
        ]
        for body: String in bodies {
            do {
                _ = try JSONDecoder().decode(EventDeduplicationPolicy.self, from: .init(body.utf8))
                Issue.record("應該解不出來：\(body)")
            } catch let DecodingError.dataCorrupted(context) {
                #expect(context.codingPath.map(\.stringValue) == ["seconds"], "\(body)")
                #expect(context.debugDescription.contains("讀不出數值"), "\(body)")
            }
        }
    }

    /// 下溢成 0 的字面值不得被靜默收下成「完全不抑制」——帶負號的更不行，那正是型別層用
    /// 無號秒數要擋掉的東西。
    ///
    /// 一併釘住訊息與真因：這條路徑上的錯誤是本型別自己造的，若哪天標準庫改成在容器層就把
    /// 數值錯誤包成 `DecodingError`，這裡會變成原樣轉拋——`codingPath` 仍是 `seconds`、
    /// 測試卻該紅。
    @Test
    func `a value that underflows to zero is rejected`() throws {
        for body: String in [#"{"mode":"window","seconds":1e-400}"#, #"{"mode":"window","seconds":-1e-400}"#] {
            do {
                let decoded: EventDeduplicationPolicy = try JSONDecoder().decode(
                    EventDeduplicationPolicy.self,
                    from: .init(body.utf8)
                )
                Issue.record("應該解不出來，卻得到 \(decoded)：\(body)")
            } catch let DecodingError.dataCorrupted(context) {
                #expect(context.codingPath.map(\.stringValue) == ["seconds"], "\(body)")
                #expect(context.debugDescription.contains("無法以整數精確表示"), "\(body)")
                #expect(context.underlyingError != nil, "\(body)")
            }
        }
    }

    /// 值根本不是數字時，原樣保留標準庫的診斷——自造一句「必須是整數」會與作者看到的東西
    /// 矛盾：他寫的 `"300"` 就是整數，錯的是那對引號。
    @Test
    func `a non numeric window keeps the standard library diagnosis`() throws {
        do {
            _ = try JSONDecoder().decode(
                EventDeduplicationPolicy.self,
                from: .init(#"{"mode":"window","seconds":"300"}"#.utf8)
            )
            Issue.record("應該解不出來")
        } catch let DecodingError.typeMismatch(_, context) {
            #expect(context.codingPath.map(\.stringValue) == ["seconds"])
        }
        do {
            _ = try JSONDecoder().decode(
                EventDeduplicationPolicy.self,
                from: .init(#"{"mode":"window","seconds":null}"#.utf8)
            )
            Issue.record("應該解不出來")
        } catch let DecodingError.valueNotFound(_, context) {
            #expect(context.codingPath.map(\.stringValue) == ["seconds"])
        }
    }

    /// 釘住 plist 路徑看不到下溢這件事——這是**現況的紀錄，不是想要的行為**。
    ///
    /// plist 在 parse 階段就把 `-1e-400` 收斂成 `0.0`，字面值進不到解碼期，本模組的下溢守衛
    /// 因此在該路徑上失效。寫成測試是為了讓這個限制有看守者：plist 哪天改成保留字面值或
    /// 直接拒絕，這條會紅，屆時該回頭修的是那句 DocC，而不是把測試改綠。
    @Test
    func `the property list path cannot see an underflowed literal`() throws {
        let xml: String = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>mode</key><string>window</string>
            <key>seconds</key><real>-1e-400</real>
            </dict></plist>
            """
        let decoded: EventDeduplicationPolicy = try PropertyListDecoder().decode(
            EventDeduplicationPolicy.self,
            from: .init(xml.utf8)
        )
        #expect(decoded == .window(seconds: 0))
    }

    /// 也要走得過非 JSON 的 decoder。
    ///
    /// `Decimal` 的 Codable 走的是 keyed container，只有 `JSONDecoder` 有把數字直接轉
    /// `Decimal` 的特例——解碼端若以 `Decimal` 為主，本型別 encode 出去的無號整數換個
    /// decoder 就讀不回來。這條測試是那個取捨的唯一守門員。
    @Test
    func `round trips through property list`() throws {
        let policies: [EventDeduplicationPolicy] = [
            .permanent,
            .window(seconds: 0),
            .window(seconds: 45),
            .window(seconds: .max)
        ]
        for format: PropertyListSerialization.PropertyListFormat in [.binary, .xml] {
            let encoder: PropertyListEncoder = .init()
            encoder.outputFormat = format
            let data: Data = try encoder.encode(policies)
            let decoded: [EventDeduplicationPolicy] = try PropertyListDecoder().decode(
                [EventDeduplicationPolicy].self,
                from: data
            )
            #expect(decoded == policies, "\(format)")
        }
    }

    /// 欄位名打錯不得靜默忽略：組態作者以為設了一個窗，實際拿到的是永久抑制。
    @Test
    func `decoding rejects an unknown field`() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                EventDeduplicationPolicy.self,
                from: .init(#"{"mode":"permanent","second":300}"#.utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                EventDeduplicationPolicy.self,
                from: .init(#"{"mode":"window","seconds":60,"window":30}"#.utf8)
            )
        }
    }

    /// `permanent` 帶了 `seconds` 欄一律拒絕：寫的人以為設了窗、拿到的卻是永久抑制。
    @Test
    func `decoding rejects permanent carrying a seconds field`() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                EventDeduplicationPolicy.self,
                from: .init(#"{"mode":"permanent","seconds":300}"#.utf8)
            )
        }
    }

    /// 編碼後解回同值；`permanent` 不帶 `seconds` 欄。編碼與解碼兩側的值域必須對稱，
    /// 故連無號型別的上限值也要能走完一圈。
    @Test
    func `round trips through json`() throws {
        let encoder: JSONEncoder = .init()
        let decoder: JSONDecoder = .init()
        for policy: EventDeduplicationPolicy in [.permanent, .window(seconds: 45), .window(seconds: .max)] {
            let data: Data = try encoder.encode(policy)
            #expect(try decoder.decode(EventDeduplicationPolicy.self, from: data) == policy)
        }
        let permanentData: Data = try encoder.encode(EventDeduplicationPolicy.permanent)
        let permanentJSON: String = try #require(String(bytes: permanentData, encoding: .utf8))
        #expect(permanentJSON.contains("seconds") == false)
    }
}
