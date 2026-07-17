// swift-tools-version:6.0
//
//  LabController
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package: Package = .init(
    name: "LabController",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LabControllerKit", targets: ["LabControllerKit"]),
    ],
    targets: [
        .target(name: "LabControllerKit"),
        .testTarget(name: "LabControllerKitTests", dependencies: ["LabControllerKit"]),
    ]
)
