// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// For local development, set the environment variable SWIFTXDEV=1 in Xcode or Terminal.
/// In this project, SWIFTXDEV=1 is only set in the .xcproj User-Defined settings for DEBUG config.
let useLocal = ProcessInfo.processInfo.environment["SWIFTXDEV"] != nil
let repo = "https://github.com/gistya/SwiftXState.git"
let swiftXMinVersion: Version = "0.9.0"

let package = Package(
    name: "SwiftXChessOpenings",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "SwiftXChessOpenings",
            targets: ["SwiftXChessOpenings"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/chesskit-app/chesskit-swift", from: "0.17.0"),
        useLocal
            ? .package(
                name: "SwiftXState",
                path: "../../../swift-xstate"
            )
            : .package(url: repo, from: swiftXMinVersion),
    ],
    targets: [
        .target(
            name: "SwiftXChessOpenings",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "ChessKit", package: "chesskit-swift"),
            ],
            path: "Sources/SwiftXChessOpenings",
            resources: [
                .copy("Resources/openings-5move.json"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SwiftXChessOpeningsTests",
            dependencies: [
                "SwiftXChessOpenings",
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "SwiftXStateInspect", package: "SwiftXState"),
            ],
            path: "Tests/"
        ),
    ]
)
