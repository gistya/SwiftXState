// swift-tools-version: 6.1
import PackageDescription
import Foundation

// A minimal WebAssembly proof-of-concept: the SwiftXState *core* engine running live in the
// browser, driving the DOM through JavaScriptKit. Build with the swift.org Wasm SDK:
//
//   swift package --swift-sdk swift-6.3.2-RELEASE_wasm js -c release
//
// then serve the generated bundle (see README). Depends only on the core `SwiftXState`
// product — no AppKit/SwiftUI/SceneKit modules — which is what makes it Wasm-clean.

/// For local development, set the environment variable SWIFTXDEV=1 in Xcode or Terminal.
/// In this project, SWIFTXDEV=1 is only set in the .xcproj User-Defined settings for DEBUG config.
let useLocal = ProcessInfo.processInfo.environment["SWIFTXDEV"] != nil
let repo = "https://github.com/gistya/SwiftXState.git"
let swiftXMinVersion: Version = "0.9.10"

let package = Package(
    name: "WasmDemo",
    dependencies: [
        useLocal
            ? .package(
                name: "SwiftXState",
                path: "../../.."
            )
            : .package(url: repo, from: swiftXMinVersion),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.53.0")),
    ],
    targets: [
        .executableTarget(
            name: "WasmDemo",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        )
    ]
)
