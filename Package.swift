// swift-tools-version: 6.1
import PackageDescription
import Foundation

// The Windows/C# bridge emits `@_cdecl` C exports only when SWIFTXWIN is set at build time. The
// manifest turns the env var into a `-D SWIFTXWIN` define; the hand-written `@_cdecl` peers in the
// bridge sources are wrapped in `#if SWIFTXWIN`.
let winBridgeSwiftSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["SWIFTXWIN"] != nil ? [.define("SWIFTXWIN")] : []

let appleUIPlatforms: [Platform] = [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .macCatalyst]
let appleWebSocketPlatforms: [Platform] = [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .macCatalyst]

// Apple minimums below. SwiftXState + SwiftXStateInspect also target Linux and Windows
// (see README platform table); those OSes are not listed here because Package.swift
// `platforms` only carries Apple deployment targets.
let package = Package(
    name: "SwiftXState",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macCatalyst(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .visionOS(.v2),
        .watchOS(.v11),
    ],
    products: [
        .library(
            name: "SwiftXState",
            targets: ["SwiftXState"],
        ),
        // `Codable` adapters for the core (persistence, replay, params, Encodable⇄JSONValue).
        // The core itself is Codable-free so it can target Embedded Swift.
        .library(
            name: "SwiftXStateCodable",
            targets: ["SwiftXStateCodable"]
        ),
        .library(
            name: "SwiftXStateSwiftUI",
            targets: ["SwiftXStateSwiftUI"]
        ),
        .library(
            name: "SwiftXStateGraph",
            targets: ["SwiftXStateGraph"]
        ),
        .library(
            name: "SwiftXStateInspectorUI",
            targets: ["SwiftXStateInspectorUI"]
        ),
        // Platform-neutral inspector logic (models, JSON-tree helpers, definition importer, and the
        // InspectorState reducer). No SwiftUI/Observation — usable on Linux and in the browser (Wasm).
        .library(
            name: "SwiftXStateInspectorCore",
            targets: ["SwiftXStateInspectorCore"]
        ),
        .library(
            name: "SwiftXStateInspect",
            targets: ["SwiftXStateInspect"]
        ),
        .library(
            name: "SwiftXStateInspectLog",
            targets: ["SwiftXStateInspectLog"]
        ),
        .library(
            name: "SwiftXStateInspectURLSession",
            targets: ["SwiftXStateInspectURLSession"]
        ),
        .library(
            name: "SwiftXStateSwiftData",
            targets: ["SwiftXStateSwiftData"]
        ),
        .library(
            name: "SwiftXStateWinBridge",
            type: .dynamic,
            targets: ["SwiftXStateWinBridge"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
        .package(url: "https://github.com/gistya/swift-compositional-init", from: "1.1.2"),
        .package(url: "https://github.com/gistya/friday-the-thirteenth", from: "2.0.0"),
    ],
    targets: [
        // The Embedded-capable core: no `Codable` machinery, no reflection-based JSON, no Foundation.
        // `JSONValue` is written/parsed by the hand-rolled codec in `JSONValueCodec.swift`.
        .target(
            name: "SwiftXState",
            dependencies: [
                .product(name: "CompositionalInit", package: "swift-compositional-init"),
            ],
            path: "Sources/SwiftXState",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // The `Codable` adapter layer — mirrors how FridayTheCodable sits beside FridayTheThirteenth.
        // Import it to give a `Codable` context ``ContextPersistable`` for free, and to get the
        // Codable-constrained persistence / replay / params APIs.
        .target(
            name: "SwiftXStateCodable",
            dependencies: [
                "SwiftXState",
                .product(name: "FridayTheCodable", package: "friday-the-thirteenth"),
            ],
            path: "Sources/SwiftXStateCodable",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "SwiftXStateSwiftUI",
            dependencies: ["SwiftXState"],
            path: "Sources/SwiftXStateSwiftUI",
            swiftSettings: [
                .define("SWIFTXSTATE_APPLE_UI", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .target(
            name: "SwiftXStateGraph",
            dependencies: ["SwiftXState"],
            path: "Sources/SwiftXStateGraph",
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: [
                .define("SWIFTXSTATE_GRAPH_UI", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .target(
            name: "SwiftXStateInspectorCore",
            dependencies: ["SwiftXState"],
            path: "Sources/SwiftXStateInspectorCore"
        ),
        .target(
            name: "SwiftXStateInspectorUI",
            dependencies: ["SwiftXState", "SwiftXStateGraph", "SwiftXStateInspectorCore"],
            path: "Sources/SwiftXStateInspectorUI",
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: [
                .define("SWIFTXSTATE_INSPECTOR_UI", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .target(
            name: "SwiftXStateSwiftData",
            dependencies: ["SwiftXState", "SwiftXStateCodable"],
            path: "Sources/SwiftXStateSwiftData",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("SWIFTXSTATE_APPLE_SWIFTDATA", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .target(
            name: "SwiftXStateInspect",
            dependencies: [
                "SwiftXState",
                .product(name: "FridayTheCodable", package: "friday-the-thirteenth"),
            ],
            path: "Sources/SwiftXStateInspect",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "SwiftXStateInspectLog",
            dependencies: ["SwiftXStateInspect"],
            path: "Sources/SwiftXStateInspectLog",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "SwiftXStateInspectURLSession",
            dependencies: ["SwiftXStateInspect"],
            path: "Sources/SwiftXStateInspectURLSession",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("SWIFTXSTATE_URL_SESSION_WEBSOCKET", .when(platforms: appleWebSocketPlatforms)),
            ]
        ),
        .target(
            name: "SwiftXStateWinBridge",
            dependencies: ["SwiftXState", "SwiftXStateInspect"],
            path: "Sources/SwiftXStateWinBridge",
            swiftSettings: winBridgeSwiftSettings
        ),
        .testTarget(
            name: "SwiftXStateTests",
            dependencies: ["SwiftXState", "SwiftXStateCodable"],
            path: "Tests/SwiftXStateTests",
        ),
        .testTarget(
            name: "SwiftXStateWinBridgeTests",
            dependencies: ["SwiftXStateWinBridge"],
            path: "Tests/SwiftXStateWinBridgeTests"
        ),
        .testTarget(
            name: "SwiftXStateGraphTests",
            dependencies: ["SwiftXState", "SwiftXStateGraph"],
            path: "Tests/SwiftXStateGraphTests",
            swiftSettings: [
                .define("SWIFTXSTATE_GRAPH_UI", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .testTarget(
            name: "SwiftXStateInspectorUITests",
            dependencies: ["SwiftXState", "SwiftXStateGraph", "SwiftXStateInspectorUI"],
            path: "Tests/SwiftXStateInspectorUITests",
            swiftSettings: [
                .define("SWIFTXSTATE_INSPECTOR_UI", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .testTarget(
            name: "SwiftXStateSwiftUITests",
            dependencies: ["SwiftXState", "SwiftXStateSwiftUI"],
            path: "Tests/SwiftXStateSwiftUITests",
            swiftSettings: [
                .define("SWIFTXSTATE_APPLE_UI", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .testTarget(
            name: "SwiftXStateInspectTests",
            dependencies: [
                "SwiftXState",
                "SwiftXStateInspect",
                "SwiftXStateInspectURLSession",
            ],
            path: "Tests/SwiftXStateInspectTests",
            swiftSettings: [
                .define("SWIFTXSTATE_URL_SESSION_WEBSOCKET", .when(platforms: appleWebSocketPlatforms)),
            ]
        ),
        .testTarget(
            name: "SwiftXStateSwiftDataTests",
            dependencies: [
                "SwiftXState",
                "SwiftXStateCodable",
                "SwiftXStateSwiftData",
            ],
            path: "Tests/SwiftXStateSwiftDataTests",
            swiftSettings: [
                .define("SWIFTXSTATE_APPLE_SWIFTDATA", .when(platforms: appleUIPlatforms)),
            ]
        ),
    ]
)
