// swift-tools-version: 6.2
import PackageDescription
import Foundation

// A browser build of the SwiftXState inspector (Swift → WebAssembly), mirroring the native
// Stately-style inspector but rendered with the DOM via JavaScriptKit.
//
//   • WebGPUGraph    — a reusable GPU state-machine graph renderer (definition JSON + a <canvas>
//                      id → animated nodes/edges/arrowheads/active-state highlight). Depends only
//                      on swift-webgpu + JavaScriptKit, not SwiftXState.
//   • WebInspector   — a reusable toolkit: give it a `WebInspectorStore` (fed from any actor's
//                      inspection stream) and a container element id, and it renders the actor
//                      sidebar + State / Events / Sequence / Graph tabs (the Graph tab uses WebGPUGraph).
//   • WasmInspector  — a thin demo: spins up a few SwiftXState actors and points the toolkit at them.
//
// Build:  ./build.sh   (uses the PackageToJS plugin + the swift.org WebAssembly SDK)

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
    name: "WasmInspector",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v11),
        .tvOS(.v18),
        .macCatalyst(.v18),
    ],
    products: [
        .library(name: "WebInspector", targets: ["WebInspector"]),
    ],
    dependencies: [
        Resolver().swiftXState,
        .package(url: "https://github.com/1amageek/swift-webgpu", branch: "main"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.53.0")),
    ],
    targets: [
        // GPU state-machine graph renderer (formerly the WasmGPUDemo example). Reusable on its own:
        // give it a machine-definition JSON + a <canvas> id. Depends only on swift-webgpu +
        // JavaScriptKit, not on SwiftXState.
        .target(
            name: "WebGPUGraph",
            dependencies: [
                .product(name: "SwiftWebGPU", package: "swift-webgpu"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ]
        ),
        .target(
            name: "WebInspector",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "SwiftXStateInspectorCore", package: "SwiftXState"),
                "WebGPUGraph",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ]
        ),
        .executableTarget(
            name: "WasmInspector",
            dependencies: [
                "WebInspector",
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        ),
    ]
)
