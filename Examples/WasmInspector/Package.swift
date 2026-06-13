// swift-tools-version: 6.2
import PackageDescription

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
let package = Package(
    name: "WasmInspector",
    products: [
        .library(name: "WebInspector", targets: ["WebInspector"]),
    ],
    dependencies: [
        .package(name: "swift-xstate", path: "../.."),
        .package(name: "WasmGPUDemo", path: "../WasmGPUDemo"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.53.0")),
    ],
    targets: [
        .target(
            name: "WebInspector",
            dependencies: [
                .product(name: "SwiftXState", package: "swift-xstate"),
                .product(name: "SwiftXStateInspectorCore", package: "swift-xstate"),
                .product(name: "WebGPUGraph", package: "WasmGPUDemo"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ]
        ),
        .executableTarget(
            name: "WasmInspector",
            dependencies: [
                "WebInspector",
                .product(name: "SwiftXState", package: "swift-xstate"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        ),
    ]
)
