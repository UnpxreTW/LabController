//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation

/// 把決策日誌的紀錄逐行 append 進一個 NDJSON 檔。
///
/// ``DecisionLogEntry`` 只負責「一則紀錄 ⇄ 一行文字」、刻意零 I/O；這個型別是它缺的另一半——
/// 把行接上換行、落進檔案，並負責落檔本身的三件正確性：**單一寫入者**、**寫完即落地**、
/// **上一次寫到一半也不會污染下一則紀錄**。
///
/// ## 兩層串行：actor 與 `O_APPEND`
///
/// 兩個併發的寫入若各自「seek 到檔尾、再寫」，兩次動作之間檔尾就變了——後寫的那則會蓋在前一則
/// 身上，兩則都毀。這裡兩層都上：actor 讓同一個實例的 append 串行；檔案以 `O_APPEND` 開啟，
/// 由核心保證每次 `write` 都落在當下的檔尾，**同一台機器上的其他實例、甚至其他行程同時寫也不會
/// 互蓋**。單靠 actor 只擋得住同一個實例，而「一檔一實例」是約定、不是機器能保證的事。
///
/// ## 為什麼每次都 `synchronize()`
///
/// 日誌的用途是**事故取證**——最有價值的一則往往正是行程死掉前寫的那則。決策輪是秒級、每輪寥寥
/// 幾行，落地成本可忽略。
///
/// ⚠ 精確的保證範圍：`synchronize()`（`fsync`）把資料交到**核心**手上，因此行程當掉、核心 panic
/// 都不會讓已回傳的 append 消失；但在 Darwin 上 `fsync` **不保證碟片已實際寫入**，突然斷電仍可能
/// 掉最後幾筆——要那一級得用 `F_FULLFSYNC`，代價高出一個量級。
///
/// 不付那個代價的理由是損傷的**種類**：斷電掉的是「還沒落盤的最後幾筆」，那幾筆會整筆消失，
/// 讀取端分不出它與「從來沒寫過」的差別——這一點不必粉飾。但它換來的是永遠不會有一則**內容錯誤**
/// 的紀錄留在日誌裡。取證要的是「寫著的都算數」，「可能少了幾筆」比「有一筆是錯的」好收拾。
public actor DecisionLogFile {

    /// 落檔失敗的具名原因。
    public enum Failure: Error, Equatable {

        /// 開檔（必要時建檔）失敗；`code` 是當下的 `errno`，用來分辨目錄不存在、權限不足等原因。
        case cannotOpenFile(path: String, code: Int32)
    }

    /// 新檔的權限：僅擁有者可讀寫。
    ///
    /// ⚠ 這**不是**秘密的邊界——依 schema 設計，紀錄裡沒有任何欄位裝得下秘密，遮蔽留在上游的
    /// trace 層。這裡防的是另一件事：日誌記著專案路徑、事件鑰匙、處置理由這類營運內情，同機
    /// 其他帳號沒有理由讀得到。屬縱深防禦、不是唯一防線。
    private static let newFilePermissions: Int = 0o600

    /// 換行位元組；NDJSON 的行終止符。
    private static let newline: UInt8 = 0x0A

    /// 日誌檔位置。
    private let url: URL

    /// 指定日誌檔位置；此時不碰檔案系統，檔案在第一次 append 時才建立。
    ///
    /// - Parameter url: 日誌檔路徑；所在目錄必須已存在（本型別不代建目錄——目錄佈局是佈署的事，
    ///   由日誌自己沿路徑造目錄會讓打錯的路徑靜靜長出一棵樹）。
    public init(url: URL) {
        self.url = url
    }

    /// 追加一則紀錄。
    ///
    /// - Parameter entry: 要寫入的紀錄。
    /// - Throws: ``DecisionLogEntry/CodingFailure``（編碼失敗）、``Failure/cannotOpenFile(path:code:)``、
    ///   或檔案系統本身的錯誤。
    public func append(_ entry: DecisionLogEntry) throws {
        try append(contentsOf: [entry])
    }

    /// 依序追加多則紀錄；行序即先後。
    ///
    /// **全有全無**：所有紀錄先全部編碼完才開檔——中途某則編不出來時，檔案一個 byte 都還沒動，
    /// 不會留下「前半寫了、後半沒有」的殘局。編碼成功後的那一次寫入是單一 `write`，正常情況下
    /// 整批一起進去。
    ///
    /// 空序列是 no-op：不建檔、不修補、不落地。「這輪沒有決策」不該讓磁碟上冒出東西。
    ///
    /// - Parameter entries: 要寫入的紀錄，依序。
    /// - Throws: 同 ``append(_:)``。
    public func append(contentsOf entries: some Sequence<DecisionLogEntry>) throws {
        var payload: Data = .init()
        for entry: DecisionLogEntry in entries {
            payload.append(contentsOf: Array(try entry.jsonLine().utf8))
            payload.append(Self.newline)
        }
        guard !payload.isEmpty else { return }
        try write(payload)
    }

    /// 開檔、必要時修補未終止的尾行，然後把整批 bytes 追加到檔尾並落地；正常量級下是單一 `write`。
    ///
    /// 修補用的換行與紀錄本體**合併成同一次 `write`**：拆成兩次寫的話，兩次之間死掉會留下一個
    /// 剛補完換行、卻還沒有紀錄的檔案——等於為了修補又製造一次可中斷的狀態。
    private func write(_ payload: Data) throws {
        let handle: FileHandle = try openForAppending()
        // 關檔失敗沒有可做的補救，也不該蓋掉正在往外丟的那個錯——descriptor 收得回來就夠了。
        defer { try? handle.close() }
        var bytes: Data = payload
        if try needsTailTermination(handle) {
            bytes.insert(Self.newline, at: bytes.startIndex)
        }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }

    /// 以追加模式開檔，檔案不存在時一併建立。
    ///
    /// **建檔與開檔是同一個系統呼叫**（`O_CREAT`）——先問「檔案在不在」再決定要不要建，兩個動作
    /// 之間別人可能剛好把檔案建出來並寫了東西，接著這邊的建檔把它整份清空。一次做完就沒有那個空窗。
    /// `O_CREAT` 不會截斷既有檔案（沒有 `O_TRUNC`），既有日誌一定是被接著寫、不會被蓋掉。
    ///
    /// `O_APPEND` 讓每次 `write` 由核心放到當下的檔尾，不看也不需要檔案位置——所以下面讀檔尾那個
    /// byte 時可以隨意 seek，不影響寫入落點。開 `O_RDWR` 正是為了那次讀。
    ///
    /// 權限只在建立當下生效（且受 umask 影響）；既有檔案的權限一個 bit 都不碰——日誌檔可能是佈署
    /// 腳本或管理者刻意設過的，每次 append 都去改它，等於讓一個附帶動作蓋掉別人明確的設定。
    private func openForAppending() throws -> FileHandle {
        let path: String = url.path
        let descriptor: Int32 = open(path, O_RDWR | O_CREAT | O_APPEND, mode_t(Self.newFilePermissions))
        guard descriptor >= 0 else { throw Failure.cannotOpenFile(path: path, code: errno) }
        // 關檔交給 ``write(_:)`` 的 `defer`；不開 `closeOnDealloc`，免得同一個 descriptor 被關兩次。
        return .init(fileDescriptor: descriptor, closeOnDealloc: false)
    }

    /// 檔尾是否缺一個換行、需要先補上才能接著寫。
    ///
    /// ## 這道修補在防什麼
    ///
    /// 行程若在寫某一行的中途死掉，檔尾會留下**半行**。此時若直接 append，新紀錄會被黏在那個殘句
    /// 後面接成一行——結果不是「一則壞行加一則好行」，而是**兩則紀錄一起毀**，而且毀掉的那則好行
    /// 正是當機後第一則、通常也是最想看的那則。先補一個換行，殘句就被關在自己那一行裡，讀取端
    /// 認得出它壞掉，後面每一則都完好。
    ///
    /// 判斷只讀檔尾一個 byte，與檔案長度無關；移動讀取位置不影響寫入落點（`O_APPEND`）。
    ///
    /// ⚠ 若真有另一個寫入者在這次判斷與寫入之間補了東西，最壞情況是多寫一個換行、在日誌裡留下
    /// 一個空行——讀取端本來就會跳過空行，不會變成壞資料。
    private func needsTailTermination(_ handle: FileHandle) throws -> Bool {
        let end: UInt64 = try handle.seekToEnd()
        guard end > 0 else { return false }
        try handle.seek(toOffset: end - 1)
        return try handle.read(upToCount: 1) != Data([Self.newline])
    }
}
