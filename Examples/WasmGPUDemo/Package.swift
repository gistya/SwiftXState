// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Experimental GPU rendering in the browser, from Swift via WebAssembly.
//
//   • WebGPUGraph  — a reusable toolkit: give it an XState-style machine-definition JSON and a
//                    <canvas> id, and it renders an interactive, animated state-machine graph on
//                    the GPU (nodes, edges, arrowheads, active-state highlight, tap-to-select).
//                    Depends only on JavaScriptKit + swift-webgpu — not on SwiftXState.
//   • WasmGPUDemo  — a thin demo: builds a SwiftXState machine and points the toolkit at its
//                    definitionJSON().
//
// Build:  ./build.sh   (uses the PackageToJS plugin + the swift.org WebAssembly SDK)

/// For local development, set the environment variable SWIFTXDEV=1 in Xcode or Terminal.
/// In this project, SWIFTXDEV=1 is only set in the .xcproj User-Defined settings for DEBUG config.
let useLocal = ProcessInfo.processInfo.environment["SWIFTXDEV"] != nil
let repo = "https://github.com/gistya/SwiftXState.git"
let swiftXMinVersion: Version = "0.9.10"

let package = Package(
    name: "WasmGPUDemo",
    products: [
        .library(name: "WebGPUGraph", targets: ["WebGPUGraph"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-webgpu", branch: "main"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.53.0")),
        useLocal
            ? .package(
                name: "SwiftXState",
                path: "../../.."
            )
            : .package(url: repo, from: swiftXMinVersion),
    ],
    targets: [
        .target(
            name: "WebGPUGraph",
            dependencies: [
                .product(name: "SwiftWebGPU", package: "swift-webgpu"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ]
        ),
        .executableTarget(
            name: "WasmGPUDemo",
            dependencies: [
                "WebGPUGraph",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "SwiftXState", package: "SwiftXState"),
            ]
        ),
    ]
)
