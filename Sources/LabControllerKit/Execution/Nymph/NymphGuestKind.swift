//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ArgumentParser

/// 要 nymph 開哪一種 guest。
///
/// **這一欄在線上是必填的、也沒有預設**：對面同一組別名可能同時存在於兩種 guest 的別名空間
/// 裡，靠別名字面去猜是哪一種，會在同名的那一個上靜默選錯引擎——選錯不會報錯，只會開出一台
/// 跑不動這件工作的機器。所以本側也不猜：要開哪一種由建立後端的人寫出來（見
/// ``NymphBackendConfiguration``）。
///
/// **本側協議的 ``GuestSpecification`` 沒有這一欄**，是刻意的：那份協議描述的是「一個一次性
/// 執行環境」，而「mac 還是 linux」是這一個後端選引擎的方式，不是每一種後端都有的概念。要
/// 讓同一個後端實例按工作分流時，該加的是分流規則，不是把這一欄推進通用協議裡。
public enum NymphGuestKind: String, Sendable, Equatable, CaseIterable {

    /// macOS guest。
    case mac

    /// Linux guest。
    case linux
}

extension NymphGuestKind: Encodable {

    // 線上就是 `"mac"`／`"linux"` 兩個字面值，合成的實作即為所需；conformance 分出來的理由
    // 是型別本體只留語意，見風格指南。
}

extension NymphGuestKind: ExpressibleByArgument {

    // 命令列要打的字面值與線上的是同兩個，合成的實作即為所需；`CaseIterable` 讓 `--help`
    // 自己列出可用值、打錯時由 ArgumentParser 直接擋在解析階段。
}
