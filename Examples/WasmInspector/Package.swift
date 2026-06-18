// swift-tools-version: 6.2
import PackageDescription
import Foundation

// A browser build of the SwiftXState inspector (Swift → WebAssembly), mirroring the native
// Stately-style inspector but rendered with the DOM via JavaScriptKit.
//
//   • WebInspector   — a reusable toolkit: give it a `WebInspectorStore` (fed from any actor's
//                      inspection stream) and a container element id, and it renders the actor
//                      sidebar + State / Events / Sequence / Graph tabs. The Graph tab reuses the
//                      GPU `WebGPUGraph` renderer from the sibling WasmGPUDemo package.
//   • WasmInspector  — a thin demo: spins up a few SwiftXState actors and points the toolkit at them.
//
// Build:  ./build.sh   (uses the PackageToJS plugin + the swift.org WebAssembly SDK)

/// For local development, set the environment variable SWIFTXDEV=1 in Xcode or Terminal.
/// In this project, SWIFTXDEV=1 is only set in the .xcproj User-Defined settings for DEBUG config.
let useLocal = ProcessInfo.processInfo.environment["SWIFTXDEV"] != nil
let repo = "https://github.com/gistya/SwiftXState.git"
let swiftXMinVersion: Version = "0.9.10"

let package = Package(
    name: "WasmInspector",
    products: [
        .library(name: "WebInspector", targets: ["WebInspector"]),
    ],
    dependencies: [
        useLocal
            ? .package(
                name: "SwiftXState",
                path: "../../.."
            )
            : .package(url: repo, from: swiftXMinVersion),
        .package(name: "WasmGPUDemo", path: "../WasmGPUDemo"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.53.0")),
    ],
    targets: [
        .target(
            name: "WebInspector",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "SwiftXStateInspectorCore", package: "SwiftXState"),
                .product(name: "WebGPUGraph", package: "WasmGPUDemo"),
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
