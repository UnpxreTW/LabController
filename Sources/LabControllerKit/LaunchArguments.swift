//
//  LabControllerKit
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

/// 解析啟動引數時可能拋出的錯誤；訊息已含 `lab-controller:` 前綴，可直接印到 stderr。
public enum LaunchArgumentError: Error, CustomStringConvertible, Equatable {

    /// 不認得的旗標。
    case unknownArgument(String)

    /// 旗標缺少後續值。
    case missingValue(String)

    /// 旗標的值格式不合法（例如 `--poll-interval` 給了非整數）。
    case invalidValue(flag: String, value: String)

    public var description: String {
        switch self {
        case .unknownArgument(let argument):
            return "lab-controller: unknown argument '\(argument)'"
        case .missingValue(let flag):
            return "lab-controller: missing value for '\(flag)'"
        case .invalidValue(let flag, let value):
            return "lab-controller: invalid value '\(value)' for '\(flag)'"
        }
    }
}

/// 從啟動引數解析出 `Config`；所有參數皆於行程啟動時注入、不讀任何設定檔。
/// 未給 `--version`／`--poll-interval` 時採用 `Config` 的預設值，遇未知旗標、
/// 缺值或格式不合法即拋錯，交由呼叫端決定如何回報並結束行程。
public func parseLaunchArguments(_ arguments: [String]) throws -> Config {
    var version: String = Config.default.version
    var intervalSeconds: Int = Config.default.poll.intervalSeconds
    var index: Int = arguments.startIndex
    while index < arguments.endIndex {
        let argument: String = arguments[index]
        switch argument {
        case "--version":
            let valueIndex: Int = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { throw LaunchArgumentError.missingValue(argument) }
            version = arguments[valueIndex]
            index = arguments.index(after: valueIndex)
        case "--poll-interval":
            let valueIndex: Int = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else { throw LaunchArgumentError.missingValue(argument) }
            let rawValue: String = arguments[valueIndex]
            guard let parsedValue: Int = Int(rawValue) else {
                throw LaunchArgumentError.invalidValue(flag: argument, value: rawValue)
            }
            intervalSeconds = parsedValue
            index = arguments.index(after: valueIndex)
        default:
            throw LaunchArgumentError.unknownArgument(argument)
        }
    }
    return Config(version: version, poll: .init(intervalSeconds: intervalSeconds))
}
