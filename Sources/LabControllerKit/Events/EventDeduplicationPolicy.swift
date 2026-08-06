//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 同一把去重鑰匙重複偵測到時的抑制政策：上次發過之後，多久之內不再發。
///
/// 政策掛在型別上（見 ``EventTypeDefinition``）、不編進鑰匙字串裡——鑰匙只回答「是不是
/// 同一件事」，抑制多久是規章，改規章不該讓既有鑰匙全部失效。
public enum EventDeduplicationPolicy: Sendable, Equatable, Codable {

    /// 發過一次就永不再發；用於「處置一次即定局」的事件，重發不帶來新資訊、只是把同一件事
    /// 再送出一次。
    case permanent

    /// 發過之後在指定秒數內抑制，逾時可再發；`0` 代表完全不抑制。
    ///
    /// 秒數用無號型別，是為了讓「負窗」在型別層就不可表達：負窗會讓
    /// ``suppressesEmission(lastEmittedAt:now:)`` 在任何時刻都回 false，該型別於是每輪重發、
    /// 而且沒有任何一處會報錯。只在解碼時擋不夠——public 建構點同樣進得來。
    case window(seconds: UInt)

    /// 自組態解碼；下列情形失敗，不猜測意圖：出現未知欄位、`mode` 不是認得的值、
    /// `permanent` 帶了 `seconds`（設了窗卻拿到永久抑制）、`window` 缺 `seconds`、
    /// `seconds` 不是 `0...UInt.max` 的整數，或 `seconds` 根本不是合法的數字字面值。
    ///
    /// ⚠ 最後兩項擋得到多少，**取決於 decoder 把數字保留到什麼程度**——沒有哪個 decoder 全
    /// 擋得住，別把 `seconds` 的合法性整個押在本型別上。`JSONDecoder` 把字面值原樣留到解碼
    /// 期，擋得住下溢與超出範圍；plist 這種在 parse 階段就把 `-1e-400` 收斂成 `0.0` 的格式，
    /// 字面值在進到本型別之前就沒了，那條路徑上的下溢會被當成 `seconds: 0`（＝完全不抑制）
    /// 收下。共通的盲區是「解析時就丟掉的精度」：JSON 的 `300.0000000000000001` 一樣會收成
    /// `300`。這不是本層補得起來的洞——資訊在更早的地方就沒了。
    public init(from decoder: any Decoder) throws {
        try ConfigurationCodingKey.assertNoUnknownKeys(in: decoder, known: Self.knownKeys)
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        let mode: String = try container.decode(String.self, forKey: .mode)
        switch mode {
        case Mode.permanent.rawValue:
            // `permanent` 帶 `seconds` 一律拒絕：寫的人多半以為自己設了一個窗，靜默忽略的
            // 結果是該型別此後永不再發，而且沒有任何提示。
            guard !container.contains(.seconds) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: container.codingPath + [CodingKeys.seconds],
                        debugDescription: "去重政策 permanent 不接受 seconds 欄；要設窗請改用 window"
                    )
                )
            }
            self = .permanent
        case Mode.window.rawValue:
            self = .window(seconds: try Self.decodeWindowSeconds(from: container))
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath + [CodingKeys.mode],
                    debugDescription: "未知的去重政策 \"\(mode)\"；可用值：permanent、window"
                )
            )
        }
    }

    /// 依上次發送時刻判斷此刻是否應抑制。
    ///
    /// - Parameters:
    ///   - lastEmittedAt: 這把鑰匙上次發送的時刻；`nil` 代表從未發過。
    ///   - now: 判定基準時刻。
    /// - Returns: `true` 代表此刻不應再發。
    ///
    /// **時鐘回跳夾成零經過時間**：`lastEmittedAt` 落在 `now` 之後時（NTP 校正、跨機時鐘差）
    /// 經過時間會是負值。夾成 0 之後，有窗的政策照樣抑制——寧可晚一輪發，也不要因為時鐘跳
    /// 一下就把整批事件重發一遍；而 `window(seconds: 0)` 這種「完全不抑制」的設定也不會
    /// 因為別台機器的時鐘快一毫秒就突然開始抑制。
    ///
    /// ⚠ 這個方向的代價：`lastEmittedAt` 若遠在未來（大幅時鐘跳動、或寫壞的紀錄），有窗的
    /// 政策會一路抑制到 `now` 追上為止，且不會有任何提示。此處刻意不設容忍上限——壞掉的
    /// 時間戳該在寫入端擋，在這裡靠猜只會把「資料錯了」變成「行為說不清楚」。
    public func suppressesEmission(lastEmittedAt: Date?, now: Date) -> Bool {
        guard let lastEmittedAt else {
            return false
        }
        switch self {
        case .permanent:
            return true
        case let .window(seconds):
            let elapsed: TimeInterval = max(0, now.timeIntervalSince(lastEmittedAt))
            return elapsed < TimeInterval(seconds)
        }
    }

    /// 編碼回組態形狀；`permanent` 不帶 `seconds` 欄。
    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .permanent:
            try container.encode(Mode.permanent.rawValue, forKey: .mode)
        case let .window(seconds):
            try container.encode(Mode.window.rawValue, forKey: .mode)
            try container.encode(seconds, forKey: .seconds)
        }
    }

    /// 解出 `window` 的秒數；缺席、型別不符、數值不合法各自給指得到欄位的錯誤。
    ///
    /// 直接解成無號整數——`encode` 寫出去的也是它，兩側才對稱。（不能反過來以 `Decimal`
    /// 為主：`Decimal` 的 Codable 走 keyed container，只有 `JSONDecoder` 有把數字直接轉
    /// `Decimal` 的特例，換成 plist 之類的 decoder 就讀不回自己寫出去的值。）
    private static func decodeWindowSeconds(from container: KeyedDecodingContainer<CodingKeys>) throws -> UInt {
        guard container.contains(.seconds) else {
            throw DecodingError.keyNotFound(
                CodingKeys.seconds,
                .init(codingPath: container.codingPath, debugDescription: "去重政策 window 必須指定 seconds")
            )
        }
        do {
            let seconds: UInt = try container.decode(UInt.self, forKey: .seconds)
            try verifyDidNotUnderflow(seconds, in: container)
            return seconds
        } catch {
            // 型別不符、值為 `null` 之類會拋 `DecodingError`（上面那條 guard 拋的也是），
            // 標準庫的訊息比自造的準（「拿到的是字串」遠比「必須是整數」有用），原樣往外拋。
            guard !(error is DecodingError) else {
                throw error
            }
            // 剩下的是「數字字面值本身進不了無號整數」。這一整類 `JSONDecoder` 是在掃描階段
            // 就放棄、丟的不是 `DecodingError`，最後浮上檯面的是一句「不是合法 JSON」、
            // `codingPath` 為空——十筆定義裡第七筆寫錯完全無從定位，所以改由本型別自己造。
            //
            // ⚠ 「數值錯誤不是 `DecodingError`」是 swift-foundation 目前的分層行為、非協定
            // 明文；哪天它改成在容器層就包好，這裡會原樣轉拋一個 `codingPath` 為空的錯。
            // 看守者＝測試 `an out of range window points at the seconds field`。
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath + [CodingKeys.seconds],
                    debugDescription: windowSecondsDiagnostic(from: container),
                    underlyingError: error
                )
            )
        }
    }

    /// 擋掉「下溢成 0」的字面值。
    ///
    /// 整數解碼對 `1e-400`（**含帶負號的 `-1e-400`**）會靜默成功回 0，正好穿過「用無號型別
    /// 讓負窗不可表達」那道保證，拿到的是「完全不抑制」而非錯誤。判準＝同一欄讀不讀得出
    /// 浮點值：合法的整數字面值讀得出，下溢的那些讀不出。**只在解出 0 時對帳**——下溢偽造
    /// 得出的只有 0，其餘值不必為此多讀一次。
    ///
    /// ⚠ **這道守衛只對「把數字節點的字面值原樣留到解碼期」的 decoder 有效**（`JSONDecoder`
    /// 屬此類，已實測）。plist 這種在 parse 階段就把 `-1e-400` 收斂成 `0.0` 的格式，字面值
    /// 在進到這裡之前就沒了，讀 `Double` 會拿到 `0.0` 而順利通過——該路徑上的下溢偵測不到。
    /// 這不是可以在本層補起來的洞：資訊在更早的地方就丟了。看守者＝測試
    /// `the property list path cannot see an underflowed literal`。
    ///
    /// ⚠ 另兩個未受協定明文保證的假設：同一個鍵可以再讀一次、整數節點讀得出 `Double`。
    /// Foundation 的 JSON 與 plist decoder 都成立（已實測）；若下游換上不允許重讀、或把整數
    /// 與浮點分成兩種節點的 decoder，合法的 `seconds: 0` 會被誤拒。看守者＝測試
    /// `round trips through property list`（它的政策清單含 `window(seconds: 0)`，別拿掉那一項）。
    private static func verifyDidNotUnderflow(
        _ seconds: UInt,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard seconds == 0 else {
            return
        }
        do {
            _ = try container.decode(Double.self, forKey: .seconds)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath + [CodingKeys.seconds],
                    debugDescription: "去重窗口秒數無法以整數精確表示（例如下溢成 0 的極小值）",
                    underlyingError: error
                )
            )
        }
    }

    /// 說明 `seconds` 這一欄哪裡不對。
    ///
    /// 讀得出數值就把值印出來——那是最省事的線索。讀不出來時**不猜原因**：「遠超出可表示
    /// 範圍」（`1e400`）與「字面值本身寫壞」（`01`、`1.2.3`）在這一層長得一模一樣，兩邊都
    /// 讀不到數值，斷言其中一種只會把作者推去查錯的地方。`Decimal` 讀不到時再試 `Double`，
    /// 是為了涵蓋超出 `Decimal` 表示範圍、但 `Double` 還讀得到的那一段（如 `1e128`）。
    private static func windowSecondsDiagnostic(from container: KeyedDecodingContainer<CodingKeys>) -> String {
        let asDecimal: String? = (try? container.decode(Decimal.self, forKey: .seconds)).map { "\($0)" }
        let asDouble: String? = (try? container.decode(Double.self, forKey: .seconds)).map { "\($0)" }
        let range: String = "去重窗口秒數必須是 0 到 \(UInt.max) 之間的整數"
        guard let actual: String = asDecimal ?? asDouble else {
            return "\(range)；這個值讀不出數值——可能遠超出可表示範圍，也可能字面值本身不合法"
        }
        return "\(range)，實際讀到 \(actual)"
    }

    /// 組態表中的欄位名。
    private enum CodingKeys: String, CodingKey {
        case mode
        case seconds
    }

    /// 本型別接受的組態欄位；用來擋掉拼錯的欄位名。
    private static let knownKeys: Set<String> = [CodingKeys.mode.rawValue, CodingKeys.seconds.rawValue]

    /// `mode` 欄的合法值。
    private enum Mode: String {
        case permanent
        case window
    }
}
