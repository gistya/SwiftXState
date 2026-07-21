// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// For local development, set the environment variable SWIFTXDEV=1 in Xcode or Terminal.
/// In this project, SWIFTXDEV=1 is only set in the .xcproj User-Defined settings for DEBUG config.
struct Resolver {
    let repo = "https://github.com/gistya/SwiftXState"
    let swiftXMinVersion: Version = "2.0.0-alpha.11"

    var swiftXState: Package.Dependency {
        ProcessInfo.processInfo.environment["SWIFTXDEV"] == "1"
        ? .package(name: "SwiftXState", path: "../..")
        : .package(url: repo, from: swiftXMinVersion)
    }
}

let package = Package(
    name: "SwiftXChessOpenings",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v11),
        .tvOS(.v18),
    ],
    products: [
        .library(
            name: "SwiftXChessOpenings",
            targets: ["SwiftXChessOpenings"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/chesskit-app/chesskit-swift", from: "0.17.0"),
        Resolver().swiftXState,
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
