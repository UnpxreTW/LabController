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
/// ## 位移分頁沒有快照，所以游標只信第一頁
///
/// 站台的分頁是 `LIMIT/OFFSET`，跨頁之間沒有一致性快照。翻頁途中集合被改動——某筆資源被更新而換位、
/// 或被刪除、被移到別的專案——都會讓它後面的資源整體往前挪一格，於是某一筆恰好跨過已讀邊界，
/// **本輪永遠讀不到它，而且沒有任何跡象**。這不只發生在更新：刪除同樣造成位移，卻連一個新的時間戳
/// 都不會留下，任何「看有沒有更新的資料」的偵測法都抓不到。
///
/// 因此游標的推進**只採信第一頁**：
///
/// - 第一頁是單一請求，也就是單一快照，不受任何位移影響。
/// - `sort=asc` 保證比第一頁最大值更早的資源全部落在那一頁裡。
///
/// 於是「游標推到第一頁的最大值」是可以證明的：比它早的資源都確實讀過了。第二頁以後的資源照樣
/// **原封不動交給呼叫端**，只是不拿來推游標——它們的時刻都晚於新游標，下一輪還會再出現一次，
/// 由去重層吸收。
///
/// 實務上一輪只會有一頁（穩定運轉時每輪的異動遠少於一頁），此時第一頁的最大值就是全部的最大值、
/// 推進毫無損失。多頁只發生在補大量舊資料的場合，那時每輪前進一頁，換到的是一筆都不漏。
///
/// 排序方向因此不是偏好而是前提：`desc` 會把剛改動的資源放到第一頁（已讀過的方向），
/// 且第一頁的最大值是全集最大值，游標一次就跳到最前面，跨過的全部都讀不回來。
///
/// ### 唯一的例外：同秒群塞滿第一頁
///
/// 上面的規則有一個會卡死的邊角：**若同一秒的資源多到把第一頁塞滿**（一次交易批次改動、匯入），
/// 第一頁的最大值取整後就等於現行游標，游標永遠推不動。那不只是原地踏步——同一批資源會每一輪
/// 重新交出去一次，而且比它們新的資源永遠排在後面，多到超過翻頁預算時就再也讀不到，
/// **從重複變成真正的遺漏**。
///
/// 因此當第一頁整頁落在游標那一秒內時，改推到「本輪讀到的、秒數已越過游標的最早一筆」，
/// 也就是剛好跨出那一秒、不多跨。代價明說：**該秒的位移保護就此失效**——那一秒內若有資源在翻頁
/// 期間被移動或刪除，可能就此漏掉。結果會以 `ResourcePollResult.crossedOversizedTie` 標出來。
/// 若連跨都跨不出去（整輪預算都還在同一秒內），游標維持不動並回報 `PollCompletion.stalled`。
///
/// ## 上限：不晚於本輪起始的站台時鐘
///
/// 推進值再壓上「本輪第一個回應所帶的站台時刻」。用站台時鐘而非本機時鐘，是因為本機時鐘若走快，
/// 上限就形同虛設；取不到站台時鐘時退回本機時鐘並往前扣一段容差（往前扣只會造成重讀）。
///
/// ## 已知缺口
///
/// - **提交順序與時間戳順序不一致**：資料庫可能存在一筆 `updated_at` 寫成較早時刻、但交易在我們查詢
///   之後才提交的資料。它對本輪不可見，時間戳卻可能已落在新游標之下，於是永遠查不到。站台時鐘那道
///   上限**擋不住這種情況**（它只保證「本輪期間才寫入」的資料下一輪還在範圍內）。真正的解是讓游標
///   固定落後一段安全距離；該距離取多少取決於站台的交易時長，本片沒有依據可訂，留給接上儲存層時決定。
/// - 站台的位移分頁在 `updated_at` 上沒有第二排序鍵。上面「只信第一頁」的規則不受此影響，
///   但同一秒內的資源筆數若超過一頁，第一頁就切在平手群中間；此時整秒重讀（見 `UpdatedAfterCursor`）
///   是唯一的保護。
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

    /// 可接受的網址 scheme。
    ///
    /// 只檢查「有沒有 scheme」擋不住少寫 scheme 的 host：`gitlab.example.com:7071` 會被解析成
    /// scheme 為 `gitlab.example.com`、host 為空，一路組成一個送不到任何地方的網址才失敗。
    static let acceptedSchemes: Set<String> = ["http", "https"]

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
    ///   - host: 站台網址，須帶 `http`／`https` scheme；結尾多餘的斜線會先修剪。
    ///   - projectIdentifier: 專案數字 ID，或以 `群組/專案` 形式的完整路徑（會做百分比編碼）。
    ///   - collection: 要輪詢的集合。
    ///   - privateToken: 具讀取權的存取 token，放在 `PRIVATE-TOKEN` 標頭。
    ///   - cursor: 上一輪保存的游標；首輪傳預設值即讀全集。
    /// - Returns: 資源、推進後的游標，以及本輪走到哪裡收尾。
    /// - Throws: `GitLabAPIError`——網址組不出、狀態碼非 200、本體解不開，或分頁標頭不一致。
    ///
    /// 回傳的資源可能包含上一輪已見過的內容，去重是下游職責；**游標只採信第一頁**的理由見型別說明。
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
        var earliestBeyondCursor: Date?
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
            // 起始時刻只取自**第一個**回應。後面每一頁都晚於它，用它當上限對整輪都成立；
            // 逐頁刷新會讓上限跟著往後漂，等於沒有上限。
            if walkStartedAt == nil {
                walkStartedAt = Self.serverTime(of: response) ?? fallbackStartTime()
            }
            let batch: [Element]
            do {
                batch = try decoder.decode([Element].self, from: response.body)
            } catch {
                // 整頁一起解，所以一筆寫壞就整頁失敗、而且每輪都會再撞一次；
                // 錯誤訊息必須指得出是哪個欄位，否則只能靠猜。
                throw GitLabAPIError.undecodableCollection(Self.describe(error))
            }
            let marker: PageMarker = try .init(response: response, requestedPage: page)
            elements.append(contentsOf: batch)
            if pagesRead == 0 {
                firstPageMaximum = batch.map(\.updatedAt).max()
            }
            for element: Element in batch where cursor.wouldAdvance(to: element.updatedAt) {
                earliestBeyondCursor = min(earliestBeyondCursor ?? element.updatedAt, element.updatedAt)
            }
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
        var advanced: UpdatedAfterCursor = cursor.advanced(to: firstPageMaximum, noLaterThan: startedAt)
        // 第一頁整頁落在游標那一秒內、後面還有頁：只採信第一頁的話游標永遠推不動（見型別說明的例外）。
        let isWedgedOnTie: Bool = pagesRead > 1 && !(firstPageMaximum.map(cursor.wouldAdvance) ?? false)
        var crossedOversizedTie: Bool = false
        if isWedgedOnTie, let escape: Date = earliestBeyondCursor {
            let escaped: UpdatedAfterCursor = cursor.advanced(to: escape, noLaterThan: startedAt)
            crossedOversizedTie = escaped != cursor
            advanced = escaped
        }
        // 沒有上限時本來會不會動？用來分辨「本來就沒東西可推進」與「有東西、卻被上限壓住不動」。
        let hadRoomToAdvance: Bool = (firstPageMaximum.map(cursor.wouldAdvance) ?? false)
            || (isWedgedOnTie && earliestBeyondCursor.map(cursor.wouldAdvance) ?? false)
        let completion: PollCompletion = Self.completion(
            isTruncated: isTruncated,
            didAdvance: advanced != cursor,
            hadRoomToAdvance: hadRoomToAdvance
        )
        return .init(
            elements: elements,
            cursor: advanced,
            completion: completion,
            crossedOversizedTie: crossedOversizedTie
        )
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

    /// 把解碼錯誤壓成一行可查的敘述：指出是哪個欄位、為什麼不合。
    ///
    /// 只取解碼器自己給的位置與說明，**不含回應本體**——本體可能很大，而且不該原樣進到錯誤訊息裡。
    static func describe(_ error: any Error) -> String {
        guard let decodingError: DecodingError = error as? DecodingError else {
            return String(describing: error)
        }
        let context: DecodingError.Context? = switch decodingError {
        case let .typeMismatch(_, context), let .valueNotFound(_, context),
             let .keyNotFound(_, context), let .dataCorrupted(context):
            context
        @unknown default:
            nil
        }
        guard let context else {
            return String(describing: decodingError)
        }
        let path: String = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path)：\(context.debugDescription)"
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

    /// 由「有沒有撞到預算」「游標動了沒」「本來動不動得了」三者判本輪收尾狀態。
    ///
    /// 游標沒動有兩種完全不同的意思。**本來就沒東西可推進**（沒讀到資料，或讀到的都還在游標那一秒內）
    /// 是正常的安靜輪次；**有東西可推進卻沒動**則代表下一輪會讀到一模一樣的內容、再次沒動，
    /// 如此反覆而每一輪各自看起來都成功了。後者必須具名為 `stalled`，撞到預算而原地踏步同理。
    static func completion(isTruncated: Bool, didAdvance: Bool, hadRoomToAdvance: Bool) -> PollCompletion {
        guard didAdvance else {
            return (isTruncated || hadRoomToAdvance) ? .stalled : .complete
        }
        return isTruncated ? .truncated : .complete
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
        // 修掉結尾**所有**斜線：只修一個的話 `…example.com//` 會組出 `//api/v4/…`，路徑多一層空片段。
        let base: String = .init(host.reversed().drop { $0 == "/" }.reversed())
        var unreserved: CharacterSet = .alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let identifier: String = projectIdentifier.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GitLabAPIError.invalidURL(projectIdentifier)
        }
        let path: String = "\(base)/api/v4/projects/\(identifier)/\(collection.pathComponent)"
        guard var components: URLComponents = .init(string: path),
              let scheme: String = components.scheme,
              Self.acceptedSchemes.contains(scheme.lowercased()) else {
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
