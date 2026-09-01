//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 用 nymph 開 guest 時，那些本側協議沒有、但對面每次都要的參數。
///
/// **綁在後端實例上、不是逐次呼叫給**：``GuestSpecification`` 描述的是「拿哪份基底、放哪些
/// 檔案」，那是每一種後端都答得出來的問題；要幾顆 vCPU、開哪一種 guest，則是這一個後端才有的
/// 概念。把它們塞進通用規格裡，等於讓每個換不掉的呼叫端都得先知道自己接的是 nymph。
public struct NymphBackendConfiguration: Sendable, Equatable {

    /// 要開哪一種 guest。
    public var os: NymphGuestKind

    /// 要求的 vCPU 數。
    public var cpus: Int

    /// 要求的記憶體，GiB。
    public var memoryGiB: Int

    /// 等 guest 開到可以收命令的上限，秒。
    ///
    /// **這個上限到了不代表失敗**：對面等不到就把還在開機的那台原樣回來、不會自己收掉它。本側
    /// 收到未就緒的 guest 時會把它清掉再拋（見 ``NymphExecutionBackend/spawn(_:)``）——識別碼
    /// 沒交到呼叫端手上，不清就沒有人會清。
    public var readinessTimeoutSeconds: Int

    /// 逐欄建立。
    ///
    /// **只有 `os` 沒有預設值**：其餘三個給多給少是資源取捨，猜錯只是慢一點或浪費一點；`os`
    /// 猜錯是開出一台跑不動這件工作的機器。理由見 ``NymphGuestKind``。
    ///
    /// - Parameters:
    ///   - os: guest 種類。
    ///   - cpus: vCPU 數；預設 4。
    ///   - memoryGiB: 記憶體 GiB；預設 4。
    ///   - readinessTimeoutSeconds: 等待上限秒數；預設 180。
    public init(os: NymphGuestKind, cpus: Int = 4, memoryGiB: Int = 4, readinessTimeoutSeconds: Int = 180) {
        self.os = os
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.readinessTimeoutSeconds = readinessTimeoutSeconds
    }
}
