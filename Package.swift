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
        .executable(name: "lab-controller", targets: ["lab-controller"]),
    ],
    dependencies: [
        .package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", exact: "2.1.0"),
    ],
    targets: [
        .target(
            name: "LabControllerKit",
            plugins: [
                .plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
            ]
        ),
        .executableTarget(
            name: "lab-controller",
            dependencies: [
                "LabControllerKit",
            ],
            plugins: [
                .plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
            ]
        ),
        .testTarget(
            name: "LabControllerKitTests",
            dependencies: [
                "LabControllerKit",
            ],
            plugins: [
                .plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
            ]
        ),
    ]
)
