// swift-tools-version: 6.2
import PackageDescription

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
let package = Package(
    name: "WasmGPUDemo",
    products: [
        .library(name: "WebGPUGraph", targets: ["WebGPUGraph"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-webgpu", branch: "main"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.53.0")),
        .package(name: "swift-xstate", path: "../.."),
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
                .product(name: "SwiftXState", package: "swift-xstate"),
            ]
        ),
    ]
)
