//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 以 `updated_after` 游標輪詢專案資源的 client：翻完頁、回傳資源與推進後的游標。
///
/// 與 `JobRequestClient` 平行、不共用型別也不共用憑證：那支是 runner 協議（站台指派工作給我們），
/// 這支是事件偵測（我們去問站台發生了什麼）。前者用 runner 認證 token、後者用具讀取權的個人存取
/// token，兩者權限域不同，混用即為權限錯置。
///
/// 本型別**無狀態**：游標由呼叫端保存、每輪傳入，推進後的值隨結果回傳（理由見 `ResourcePollResult`）。
///
/// ## 排序方向為何固定 `asc`
///
/// 翻頁期間集合會被改動，而位移分頁沒有快照。差別在改動把資源推向哪一端：
///
/// - `sort=desc`：剛被改的資源跳到第一頁。那頁已經讀過了，本輪看不到它；而游標會推到「本輪讀到的
///   最大時刻」——正好越過它。**永久漏掉。**
/// - `sort=asc`：剛被改的資源移到尾端，也就是還沒讀到的方向，本輪仍會遇到。
///
/// 兩者都會因為前段資源被改動而讓後續資源整體前移一格、跨過已讀邊界；`asc` 的差別是這種漏讀**偵測得到**
/// （見下），`desc` 的漏讀連跡象都沒有。
///
/// ## 游標推進到哪一筆
///
/// - **平順情況**（讀到最後一頁，且沒有任何資源的 `updated_at` 晚於本輪起始時刻）：推進到本輪讀到的
///   最大時刻。沒有改動發生過，整段都確實讀完了。
/// - **受擾情況**（撞到翻頁預算，或讀到了本輪期間才被改動的資源）：只推進到**第一頁**的最大時刻。
///   第一頁是單一請求、即單一快照，`asc` 排序保證比它更早的資源全在那一頁裡；比它晚的部分則不保證
///   沒有被位移吃掉，於是不算數、下一輪重讀。代價是大量待讀時每輪只前進一頁，換到的是不漏。
///
/// 兩種情況都再壓上「不晚於本輪起始的**站台**時鐘」這道上限（理由見
/// `UpdatedAfterCursor.advanced(to:noLaterThan:)`）。用站台時鐘而非本機時鐘是因為本機時鐘若走快，
/// 上限就形同虛設；取不到站台時鐘時退回本機時鐘並往前扣一段容差。
///
/// ## 已知缺口
///
/// - 站台的位移分頁在 `updated_at` 上沒有第二排序鍵，真正的解是 keyset 分頁，但 16.2 的 keyset 只支援
///   以 `id` 排序、與本游標不相容。上面的保守推進是在可用工具內能做到的最好結果，不是消滅了該問題。
/// - 未處理站台的速率限制回應（429）；目前一律當非預期狀態碼拋出。
public struct ProjectResourcePoller: Sendable {

    /// 站台接受的每頁筆數上限（Kaminari `max_per_page`）。
    public static let maximumPageSize: Int = 100

    /// 預設每頁筆數；直接取上限，讓同樣的翻頁預算涵蓋最多資源。
    public static let defaultPageSize: Int = 100

    /// 預設單輪翻頁上限。有界是為了讓一輪輪詢的耗時可預期——待讀量在補資料的場景可以很大，
    /// 一輪讀到底會把整個偵測週期卡住。
    public static let defaultPageBudget: Int = 20

    /// 取不到站台時鐘時，本機時鐘往前扣的容差秒數。往前扣的方向只會造成重讀、不會造成漏讀。
    public static let defaultClockSkewAllowance: TimeInterval = 120

    /// 單次請求逾時；這類查詢應快速失敗，與 long-poll 的 `jobs/request` 相反。
    public static let requestTimeout: TimeInterval = 30

    /// 實際採用的每頁筆數，已夾在 `1 ... maximumPageSize`。
    ///
    /// 公開出來是因為站台對超限值**不報錯、直接收成上限**：呼叫端寫 500、以為一頁 500 筆，
    /// 翻頁預算涵蓋的實際筆數卻只有五分之一。在本地先夾住並讓有效值可讀，好過事後靠猜。
    public let pageSize: Int

    /// 實際採用的單輪翻頁上限，至少為 1。
    public let pageBudget: Int

    /// 實際採用的時鐘容差秒數，至少為 0。
    public let clockSkewAllowance: TimeInterval

    /// 傳輸層；正式路徑用 `URLSessionTransport`、測試注入假傳輸。
    private let transport: any HTTPTransport

    /// 取不到站台時鐘時的本機時鐘來源；測試可注入固定值。
    private let localClock: @Sendable () -> Date

    /// 以指定傳輸與翻頁參數建立；超出合理範圍的參數在此夾住，不往後傳。
    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        pageSize: Int = ProjectResourcePoller.defaultPageSize,
        pageBudget: Int = ProjectResourcePoller.defaultPageBudget,
        clockSkewAllowance: TimeInterval = ProjectResourcePoller.defaultClockSkewAllowance,
        localClock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.pageSize = min(max(pageSize, 1), Self.maximumPageSize)
        self.pageBudget = max(pageBudget, 1)
        self.clockSkewAllowance = max(clockSkewAllowance, 0)
        self.localClock = localClock
    }

    /// 讀出游標之後被改動過的資源。
    ///
    /// - Parameters:
    ///   - host: 站台網址，結尾多餘的斜線會先修剪。
    ///   - projectIdentifier: 專案數字 ID，或以 `群組/專案` 形式的完整路徑（會做百分比編碼）。
    ///   - collection: 要輪詢的集合。
    ///   - privateToken: 具讀取權的存取 token，放在 `PRIVATE-TOKEN` 標頭。
    ///   - cursor: 上一輪保存的游標；首輪傳預設值即讀全集。
    /// - Returns: 資源、推進後的游標，以及本輪走到哪裡收尾。
    /// - Throws: `GitLabAPIError`——網址組不出、狀態碼非 200、本體解不開，或分頁標頭不一致。
    ///
    /// 回傳的資源可能包含上一輪已見過的內容，去重是下游職責；**游標保守、寧可重讀**的理由見型別說明。
    public func poll<Element: Decodable & UpdatedAtCarrying>(
        host: String,
        projectIdentifier: String,
        collection: ProjectCollection,
        privateToken: String,
        cursor: UpdatedAfterCursor
    ) async throws -> ResourcePollResult<Element> {
        let decoder: JSONDecoder = Self.makeResourceDecoder()
        var elements: [Element] = []
        var firstPageMaximum: Date?
        var observedMaximum: Date?
        var walkStartedAt: Date?
        var page: Int = 1
        var pagesRead: Int = 0
        var isTruncated: Bool = false
        while true {
            let response: HTTPResponse = try await send(
                host: host,
                projectIdentifier: projectIdentifier,
                collection: collection,
                privateToken: privateToken,
                cursor: cursor,
                page: page
            )
            guard response.statusCode == 200 else {
                throw GitLabAPIError.unexpectedStatus(response.statusCode)
            }
            // 起始時刻取自**第一個**回應：它早於後續所有請求，用它當上限對每一頁都成立。
            walkStartedAt = walkStartedAt ?? Self.serverTime(of: response) ?? fallbackStartTime()
            guard let batch: [Element] = try? decoder.decode([Element].self, from: response.body) else {
                throw GitLabAPIError.undecodableBody
            }
            let marker: PageMarker = try .init(response: response, requestedPage: page)
            elements.append(contentsOf: batch)
            let batchMaximum: Date? = batch.map(\.updatedAt).max()
            if pagesRead == 0 {
                firstPageMaximum = batchMaximum
            }
            observedMaximum = [observedMaximum, batchMaximum].compactMap { $0 }.max()
            pagesRead += 1
            guard let nextPage: Int = marker.nextPage else {
                break
            }
            guard pagesRead < pageBudget else {
                isTruncated = true
                break
            }
            page = nextPage
        }
        let startedAt: Date = walkStartedAt ?? fallbackStartTime()
        let sawLaterWrite: Bool = observedMaximum.map { $0 > startedAt } ?? false
        let candidate: Date? = (isTruncated || sawLaterWrite) ? firstPageMaximum : observedMaximum
        let advanced: UpdatedAfterCursor = cursor.advanced(to: candidate, noLaterThan: startedAt)
        let completion: PollCompletion = Self.completion(
            isTruncated: isTruncated,
            movedCursor: advanced != cursor
        )
        return .init(elements: elements, cursor: advanced, completion: completion)
    }

    /// 產生本模組解 GitLab 資源用的解碼器。
    ///
    /// 時間欄位不用內建的 `.iso8601`：那個策略**不吃小數秒**，而站台送的時間戳帶著小數位。
    /// 症狀是整頁解碼失敗、輪詢當場中斷，而錯誤訊息只會說某個欄位格式不對，看不出是精度問題。
    /// 這裡改成兩種形狀都接受。
    ///
    /// 鍵名不套 `.convertFromSnakeCase`：本 repo 既有的解碼型別一律自帶 `CodingKeys`，
    /// 明寫的對應在欄位含縮寫或數字時才不會出錯，也讓「站台欄位叫什麼」在原始碼裡看得到。
    public static func makeResourceDecoder() -> JSONDecoder {
        let decoder: JSONDecoder = .init()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw: String = try decoder.singleValueContainer().decode(String.self)
            guard let date: Date = Self.parseTimestamp(raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "不是可解析的 ISO-8601 時間戳：\(raw)")
                )
            }
            return date
        }
        return decoder
    }

    /// 解 ISO-8601 時間戳，帶不帶小數秒都收。
    static func parseTimestamp(_ raw: String) -> Date? {
        if let date: Date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
            return date
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(raw)
    }

    /// 從回應的 `Date` 標頭取站台時鐘；標頭缺席或格式不符時回 `nil`。
    ///
    /// 格式為 HTTP 規定的 IMF-fixdate（`Sun, 06 Nov 1994 08:49:37 GMT`）。locale 必須釘死
    /// `en_US_POSIX`：跟隨系統 locale 會讓同一份回應在不同地區設定的機器上解析結果不同。
    static func serverTime(of response: HTTPResponse) -> Date? {
        guard let raw: String = response.headerValue("Date") else {
            return nil
        }
        let formatter: DateFormatter = .init()
        formatter.locale = .init(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }

    /// 由「有沒有撞到預算」與「游標動了沒」判本輪收尾狀態。
    ///
    /// 撞到預算又推不動游標＝下一輪會讀到一模一樣的內容再撞一次；這種會自我重複的狀態必須具名，
    /// 否則每一輪各自看起來都成功了。
    static func completion(isTruncated: Bool, movedCursor: Bool) -> PollCompletion {
        guard isTruncated else {
            return .complete
        }
        return movedCursor ? .truncated : .stalled
    }

    /// 取不到站台時鐘時的替代起始時刻：本機時鐘往前扣容差。
    private func fallbackStartTime() -> Date {
        localClock().addingTimeInterval(-clockSkewAllowance)
    }

    /// 組出單頁請求並送出。
    private func send(
        host: String,
        projectIdentifier: String,
        collection: ProjectCollection,
        privateToken: String,
        cursor: UpdatedAfterCursor,
        page: Int
    ) async throws -> HTTPResponse {
        let base: String = host.hasSuffix("/") ? .init(host.dropLast()) : host
        var unreserved: CharacterSet = .alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let identifier: String = projectIdentifier.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GitLabAPIError.invalidURL(projectIdentifier)
        }
        let path: String = "\(base)/api/v4/projects/\(identifier)/\(collection.pathComponent)"
        guard var components: URLComponents = .init(string: path), components.scheme != nil else {
            throw GitLabAPIError.invalidURL(host)
        }
        var items: [URLQueryItem] = [
            // order_by／sort 不開放呼叫端覆寫：游標的正確性建立在這個排序上（見型別說明）。
            .init(name: "order_by", value: "updated_at"),
            .init(name: "sort", value: "asc"),
            .init(name: "per_page", value: .init(pageSize)),
            .init(name: "page", value: .init(page)),
        ]
        if let updatedAfter: String = cursor.queryValue {
            items.append(.init(name: "updated_after", value: updatedAfter))
        }
        components.queryItems = items
        guard let url: URL = components.url else {
            throw GitLabAPIError.invalidURL(path)
        }
        let request: HTTPRequest = .init(
            method: "GET",
            url: url,
            headers: ["PRIVATE-TOKEN": privateToken],
            timeout: Self.requestTimeout
        )
        return try await transport.send(request)
    }
}
