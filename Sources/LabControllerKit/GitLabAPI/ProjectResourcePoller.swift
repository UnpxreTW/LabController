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
/// ### 會卡住的邊角：同秒群塞滿第一頁
///
/// 上面的規則有一個推不動的形狀：**若同一秒的資源多到把第一頁塞滿**（一次交易批次改動、匯入），
/// 第一頁的最大值取整後就等於現行游標，游標不會動，下一輪讀到一模一樣的內容。
///
/// 本型別**不會自作主張跨過去**，而是回報 `PollCompletion.stalled`。理由是「跨過去」在這個 API 形狀下
/// 無法做得安全：要跨就得先確定那一秒已經讀完，而唯一的證據只能來自第二頁以後——那正是不可採信的
/// 位置。更根本的是，站台對 `updated_at` 沒有第二排序鍵，**時間戳完全相同的資源在不同次請求之間
/// 順序未定**；同一群 tied 資源可能每次請求都回不同的子集合，於是「第二頁出現了更新的資源」
/// 完全不能推論成「那一秒讀完了」。照那個推論跨過去，沒在任何一頁露過面的同時刻資源就此沉到水位之下、
/// 永遠讀不到——而且翻頁期間一筆改動都不需要發生。
///
/// 因此本層的選擇是：**卡住但出聲，絕不用會漏資料的方式製造進度**。卡住期間資料仍在游標之上、
/// 一筆都沒丟，換個做法就讀得回來；跨過去丟掉的則沒有任何一層會發現。
///
/// 要真正解開這個形狀，需要一層握有去重狀態的呼叫端——它知道哪些已經處理過，才有依據決定
/// 「這批我全看過了，可以往前」。那個決定不屬於這一層。
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
/// - **同一秒的資源多到塞滿第一頁時輪詢會卡住**（見上一節）。卡住期間一筆資料都不會丟，
///   但游標也不會前進，比那一秒新的資源若超出翻頁預算就讀不到。解開它需要去重狀態，不在本層。
/// - 未處理站台的速率限制回應（429）；目前一律當非預期狀態碼拋出。
public struct ProjectResourcePoller: Sendable {

    /// 站台接受的每頁筆數上限（Kaminari `max_per_page`）。
    public static let maximumPageSize: Int = 100

    /// 預設每頁筆數；直接取上限，讓同樣的翻頁預算涵蓋最多資源。
    public static let defaultPageSize: Int = 100

    /// 預設單輪翻頁上限。
    ///
    /// 預設 **1**，因為游標只採信第一頁：第二頁以後不論讀幾頁，**游標都只前進一頁的量**，
    /// 那些資源下一輪還會再讀一次。實測 5000 筆待讀（各佔不同秒、每頁 100）：預算 1 需 51 輪、
    /// 51 次請求；預算 20 需 32 輪、640 次請求、傳輸量 12.8 倍——用 12.6 倍的請求換 1.6 倍的收斂速度，
    /// 且每輪交出去的資源約九成五是下一輪還會再來一次的重複，全壓在去重層身上。
    ///
    /// 調高它換到的**不是游標進度、是本輪的交件量**：待讀的資源會更早被交給呼叫端，
    /// 代價是請求數與重複量等比上升。補大量舊資料而且在意延遲時才值得調。
    public static let defaultPageBudget: Int = 1

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

    /// 量測請求來回耗時用的**單調**時鐘；測試可注入。
    ///
    /// 與 `localClock` 分開，是因為兩者要的東西不同：那個要的是「現在幾點」，這個要的是「過了多久」。
    /// 牆上時鐘會被 NTP 校時、休眠喚醒或手動改時間整段跳，拿它相減得到的「耗時」可能是負的，
    /// 於是上限退回成回應產生時刻——正好是這段程式碼要避開的值，而且不會有任何徵兆。
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    /// 以指定傳輸與翻頁參數建立；超出合理範圍的參數在此夾住，不往後傳。
    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        pageSize: Int = ProjectResourcePoller.defaultPageSize,
        pageBudget: Int = ProjectResourcePoller.defaultPageBudget,
        clockSkewAllowance: TimeInterval = ProjectResourcePoller.defaultClockSkewAllowance,
        localClock: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.transport = transport
        self.pageSize = min(max(pageSize, 1), Self.maximumPageSize)
        self.pageBudget = max(pageBudget, 1)
        self.clockSkewAllowance = max(clockSkewAllowance, 0)
        self.localClock = localClock
        self.monotonicNow = monotonicNow
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
        var sawResourceBeyondCursor: Bool = false
        var walkStartedAt: Date?
        var page: Int = 1
        var pagesRead: Int = 0
        var isTruncated: Bool = false
        while true {
            let sentAt: ContinuousClock.Instant = monotonicNow()
            let response: HTTPResponse = try await send(
                host: host,
                projectIdentifier: projectIdentifier,
                collection: collection,
                privateToken: privateToken,
                cursor: cursor,
                page: page
            )
            let roundTrip: TimeInterval = Self.seconds(of: sentAt.duration(to: monotonicNow()))
            guard response.statusCode == 200 else {
                throw GitLabAPIError.unexpectedStatus(response.statusCode)
            }
            // 起始時刻只取自**第一個**回應，且要往前扣掉那一次來回的耗時。
            // `Date` 標頭是**回應產生時**的站台時刻，晚於查詢取快照的瞬間；直接拿它當上限，
            // 上限就比快照晚了一整個請求的時間，那段期間提交的資料會落在新水位之下、再也讀不到。
            // 扣掉單調時鐘量到的來回耗時（純時距、與時鐘域無關）即得一個必定不晚於快照的時刻。
            // 逐頁刷新同樣不行——上限會跟著往後漂，等於沒有上限。
            if walkStartedAt == nil {
                walkStartedAt = Self.serverTime(of: response)?.addingTimeInterval(-roundTrip) ?? fallbackStartTime()
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
            // 只記「有沒有」、不記是哪一筆：它唯一的用途是分辨卡住與安靜，**不是**推進依據。
            // 留著一個最小值會讓下一個人以為游標可以推到那裡去，而那正是會漏資料的做法。
            sawResourceBeyondCursor = sawResourceBeyondCursor || batch.contains { cursor.wouldAdvance(to: $0.updatedAt) }
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
        // 迴圈至少跑一輪、且在該輪就設定起始時刻，否則早已拋錯離開；`??` 只是讓型別收斂。
        let startedAt: Date = walkStartedAt ?? fallbackStartTime()
        let advanced: UpdatedAfterCursor = cursor.advanced(to: firstPageMaximum, noLaterThan: startedAt)
        // 游標沒動時，下一輪會不會讀到一模一樣的東西？兩個各自獨立的來源：
        // ①看到了越過游標的資源卻推不動（被時鐘上限壓住，或同秒群塞滿第一頁）；
        // ②第一頁是空的卻還有下一頁——站台異常，第一頁沒有任何可採信的證據，游標永遠不會動。
        // ② 不可省：它可能在完全沒有「越過游標的資源」的情況下發生，那時 ① 為假、狀態卻照樣重複。
        let firstPageEmptyWithMore: Bool = firstPageMaximum == nil && pagesRead > 1
        let completion: PollCompletion = Self.completion(
            isTruncated: isTruncated,
            didAdvance: advanced != cursor,
            willRepeat: sawResourceBeyondCursor || firstPageEmptyWithMore
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
                // 原值截斷後才放進訊息：這個欄位的內容由站台端資料決定、長度不設限，
                // 原樣帶進錯誤訊息等於讓外部內容決定訊息大小。
                let shown: String = raw.count > 40 ? "\(raw.prefix(40))…" : raw
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "不是可解析的 ISO-8601 時間戳：\(shown)")
                )
            }
            return date
        }
        return decoder
    }

    /// 解 ISO-8601 時間戳，帶不帶小數秒都收。
    ///
    /// 單一 style 即可：實測 `includingFractionalSeconds: true` 對無小數秒的形式與 `+08:00` 這類位移
    /// 同樣解得開，兩邊都寬鬆。這裡不再多留一個「無小數秒」的後備分支——那條路走不到，
    /// 沒有任何測試碰得到它，只會讓人以為防線比實際更厚。真正釘住兩種形狀都解得開的是測試，
    /// 而不是分支數量；哪天 Foundation 收緊，那些測試就會轉紅。
    static func parseTimestamp(_ raw: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
    }

    /// 把 `Duration` 換算成秒。
    static func seconds(of duration: Duration) -> TimeInterval {
        let parts: (seconds: Int64, attoseconds: Int64) = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
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

    /// 由「有沒有撞到預算」「游標動了沒」「會不會重複下去」三者判本輪收尾狀態。
    ///
    /// 游標沒動有兩種完全不同的意思。**本來就沒東西可推進**（沒讀到資料，或讀到的都還在游標那一秒內）
    /// 是正常的安靜輪次；**會原封不動再來一次**則代表下一輪讀到一模一樣的內容、再次沒動，
    /// 如此反覆而每一輪各自看起來都成功了。後者必須具名為 `stalled`，撞到預算而原地踏步同理。
    static func completion(isTruncated: Bool, didAdvance: Bool, willRepeat: Bool) -> PollCompletion {
        guard didAdvance else {
            return (isTruncated || willRepeat) ? .stalled : .complete
        }
        return isTruncated ? .truncated : .complete
    }

    /// 把網址字串收斂成可安全記錄的位置描述。
    ///
    /// **絕不把原字串放進錯誤**：`https://oauth2:<token>@gitlab.example.com` 這種形狀是合法輸入，
    /// 原樣帶進 `invalidURL` 就等於把憑證寫進每一行 log 與每一份當機報告——那道守衛本來是要保護憑證的。
    /// 只保留 scheme／host／port；連這些都取不出來時回一個固定字串，不回退到原值。
    static func safeLocation(of urlString: String) -> String {
        guard let components: URLComponents = .init(string: urlString), let host: String = components.host else {
            return "<無法解析的網址>"
        }
        let scheme: String = components.scheme.map { "\($0)://" } ?? ""
        let port: String = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)\(host)\(port)"
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
        var unreserved: CharacterSet = .alphanumerics
        unreserved.insert(charactersIn: "-._~")
        // 空專案識別字會組出 `/projects//issues`：請求照樣帶著憑證送出去、站台回 404，
        // 呼叫端看到的是「查無此專案」而不是「參數沒填」。在這裡擋掉才指得出真正的原因。
        guard !projectIdentifier.isEmpty,
              let identifier: String = projectIdentifier.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GitLabAPIError.invalidURL("<專案識別字無效>")
        }
        // host 先自己解析成元件再接路徑，不先做字串串接：串接會讓帶查詢字串或片段的 host
        // 把整段 `/api/v4/…` 吞進查詢或片段裡，組出一個打在站台首頁、卻完全不像壞掉的網址。
        guard var components: URLComponents = .init(string: host),
              let scheme: String = components.scheme,
              Self.acceptedSchemes.contains(scheme.lowercased()),
              components.host?.isEmpty == false,
              components.query == nil,
              components.fragment == nil,
              // userinfo 必須擋：`https://gitlab.example.com@elsewhere.example` 會解析成
              // host 為 elsewhere.example、使用者名稱為前半段，看起來像自家站台，
              // 讀取憑證卻會連同 PRIVATE-TOKEN 標頭一起送到別人家。
              components.user == nil,
              components.password == nil else {
            throw GitLabAPIError.invalidURL(Self.safeLocation(of: host))
        }
        // 修掉結尾**所有**斜線：只修一個的話 `…example.com//` 會組出 `//api/v4/…`，路徑多一層空片段。
        let base: String = .init(components.percentEncodedPath.reversed().drop { $0 == "/" }.reversed())
        // 用 percentEncodedPath 而非 path：後者的 setter 視傳入值為未編碼，會把 `%2F` 再編成 `%252F`。
        components.percentEncodedPath = "\(base)/api/v4/projects/\(identifier)/\(collection.pathComponent)"
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
            throw GitLabAPIError.invalidURL(Self.safeLocation(of: host))
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
