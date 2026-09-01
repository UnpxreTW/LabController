//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// GitLab API 呼叫的錯誤模型；涵蓋網址組裝、回應形狀與狀態碼三類失敗。
public enum GitLabAPIError: Error, Equatable, Sendable {

    /// host 字串組不出帶 scheme 的合法網址；附帶的是**收斂過的位置描述**，不是原字串。
    ///
    /// `https://oauth2:<token>@gitlab.example.com` 是合法輸入，而這條錯誤會被寫進 log 與當機報告——
    /// 原字串照放等於把憑證一併寫進去，那道守衛本來是要保護憑證的。凡承載網址字串者一律經
    /// `safeLocation(of:)` 產生（見該方法），呼叫端不自行組字串；不含網址的固定說明字面值不在此列。
    case invalidURL(String)

    /// 回應不是 HTTP 回應（傳輸層形狀異常）。
    case invalidResponse

    /// 狀態碼不在該端點的預期範圍內。
    case unexpectedStatus(Int)

    /// 回應本體解不出預期的 JSON 形狀。
    ///
    /// `codingPath` 是解不開的位置（如 `id`），**刻意只帶鍵名、不帶值**：這條錯誤會被寫進
    /// log，而 body 裡有 job token 與變數值。空字串代表拿不到位置資訊。
    ///
    /// 帶著位置是因為「body 解不開」單獨一句話查不動——`JobResponse` 現在只有 `id`／`token`
    /// 缺席會走到這裡，而這兩者缺哪一個、下一步完全不同。
    case undecodableBody(codingPath: String = "")

    /// 集合本體解不開；附帶解碼器指出的位置與原因。
    ///
    /// 與 `undecodableBody` 分開，是因為集合是整頁一起解的：**一筆資源的一個欄位寫壞就會讓整頁失敗**，
    /// 而那一頁每一輪都會再讀一次，於是輪詢從此卡死。只回一個沒有內容的錯誤等於要人自己去猜是哪一筆、
    /// 哪個欄位；訊息裡帶著 `codingPath` 才有得查。內容只取解碼器的描述，不含回應本體。
    case undecodableCollection(String)

    /// 分頁標頭缺席或彼此矛盾；附帶一句說明是哪裡對不上。
    ///
    /// 獨立成一個 case 而不併進 `invalidResponse`：分頁標頭壞掉時，回應本體通常是完全合法的一頁資料，
    /// 照收就是「只讀到第一頁」或「同一頁反覆讀」——兩者都不會有任何徵兆。此處拋錯是為了讓它出聲。
    case malformedPagination(String)
}

public extension GitLabAPIError {

    /// 取不出 host 時的固定替代字串。
    ///
    /// 解不開就不回退到原值：解不開的字串一樣可能整段都是憑證，而「無法解析」本身就足以指出問題。
    static let unparsableLocation: String = "<無法解析的網址>"

    /// 把網址字串收斂成可安全記錄的位置描述：只保留 scheme／host／port。
    ///
    /// 使用者名稱、密碼、路徑與查詢字串全數捨棄——憑證可能出現在前兩者，也常被放進查詢字串。
    /// 保留的三段足以分辨「打錯站台」與「網址組壞了」，這正是這條錯誤要回答的問題。
    static func safeLocation(of urlString: String) -> String {
        guard let components: URLComponents = .init(string: urlString), let host: String = components.host else {
            return unparsableLocation
        }
        let scheme: String = components.scheme.map { "\($0)://" } ?? ""
        let port: String = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)\(host)\(port)"
    }

    /// 把任一錯誤收斂成可安全記錄的一句話：傳輸層的錯誤只留錯誤碼與經 ``safeLocation(of:)`` 收斂的位置。
    ///
    /// `URLSession` 連不上時拋的 `URLError` 會把**送出去的整條網址**放進 `userInfo`
    /// （`NSErrorFailingURLKey`；本機實跑確認），而 `--host` 收得下
    /// `https://oauth2:<token>@gitlab.example.com` 這種形狀 ⇒ 直接內插該錯誤等於把憑證寫進 log。
    /// 領件又是迴圈，站台不在的期間每個退避週期就再寫一次。
    ///
    /// 不是 `URLError` 的照原樣描述：本模組自己拋的 ``GitLabAPIError`` 在建立處就已收斂
    /// （見 ``invalidURL(_:)`` 與 ``undecodableBody(codingPath:)``），不需要第二層遮蔽。
    ///
    /// - Parameter error: 要寫進紀錄的錯誤。
    /// - Returns: 不帶憑證的一句描述。
    static func safeDescription(of error: any Error) -> String {
        guard let urlError: URLError = error as? URLError else { return .init(describing: error) }
        let location: String = urlError.failingURL.map { safeLocation(of: $0.absoluteString) } ?? unparsableLocation
        return "URLError(code: \(urlError.errorCode), location: \(location))"
    }
}
