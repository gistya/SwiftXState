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
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "SwiftXState",
            targets: ["SwiftXState"],
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
        // Keypath/case-path optics + functional record update — backs the typed DSL's
        // `<-` / `clone(mutating:)` / `cloned` and the `CasePath`/`WritableCasePath` prisms.
            .package(url: "https://github.com/gistya/swift-compositional-init", from: "1.0.0"),
    ],
    targets: [
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
            swiftSettings: [
                .define("SWIFTXSTATE_INSPECTOR_UI", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .target(
            name: "SwiftXStateSwiftData",
            dependencies: ["SwiftXState"],
            path: "Sources/SwiftXStateSwiftData",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("SWIFTXSTATE_APPLE_SWIFTDATA", .when(platforms: appleUIPlatforms)),
            ]
        ),
        .target(
            name: "SwiftXStateInspect",
            dependencies: ["SwiftXState"],
            path: "Sources/SwiftXStateInspect",
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
            dependencies: ["SwiftXState"],
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
                "SwiftXStateSwiftData",
            ],
            path: "Tests/SwiftXStateSwiftDataTests",
            swiftSettings: [
                .define("SWIFTXSTATE_APPLE_SWIFTDATA", .when(platforms: appleUIPlatforms)),
            ]
        ),
    ]
)
