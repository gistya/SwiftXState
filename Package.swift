// swift-tools-version: 6.1
import PackageDescription
import CompilerPluginSupport
import Foundation

// The Windows/C# bridge emits `@_cdecl` C exports only when SWIFTXWIN is set at build time. The
// manifest (unlike macro plugins) does see the environment, so it turns the env var into a `-D
// SWIFTXWIN` define; the @WinC macro's generated peers are wrapped in `#if SWIFTXWIN`.
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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"), 
    ],
    targets: [
        // Compiler-plugin macro target — SwiftSyntax is a *build-time* dependency only; nothing
        // from it is linked into a consumer's binary.
        .macro(
            name: "SwiftXStateMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/SwiftXStateMacros"
        ),
        .target(
            name: "SwiftXState",
            dependencies: ["SwiftXStateMacros"],
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
            name: "SwiftXStateInspectorUI",
            dependencies: ["SwiftXState", "SwiftXStateGraph"],
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
        // Tool that scans @WinC functions and generates the C# P/Invoke bridge. Run via the
        // `generate-csharp-bridge` command plugin (or directly).
        .executableTarget(
            name: "WinCBridgeGen",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            path: "Sources/WinCBridgeGen"
        ),
        .plugin(
            name: "GenerateCSharpBridge",
            capability: .command(
                intent: .custom(
                    verb: "generate-csharp-bridge",
                    description: "Regenerate the C# P/Invoke bridge from the @WinC functions"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Writes Interop/csharp/SwiftXStateWinBridge.cs"),
                ]
            ),
            dependencies: [.target(name: "WinCBridgeGen")],
            path: "Plugins/GenerateCSharpBridge"
        ),
        .testTarget(
            name: "SwiftXStateTests",
            dependencies: ["SwiftXState"],
            path: "Tests/SwiftXStateTests",
        ),
        .testTarget(
            name: "SwiftXStateMacrosTests",
            dependencies: [
                "SwiftXStateMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/SwiftXStateMacrosTests"
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
