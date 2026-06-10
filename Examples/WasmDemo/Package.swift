// swift-tools-version: 6.1
import PackageDescription

// A minimal WebAssembly proof-of-concept: the SwiftXState *core* engine running live in the
// browser, driving the DOM through JavaScriptKit. Build with the swift.org Wasm SDK:
//
//   swift package --swift-sdk swift-6.3.2-RELEASE_wasm js -c release
//
// then serve the generated bundle (see README). Depends only on the core `SwiftXState`
// product — no AppKit/SwiftUI/SceneKit modules — which is what makes it Wasm-clean.
let package = Package(
    name: "WasmDemo",
    dependencies: [
        .package(name: "swift-xstate", path: "../.."),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.53.0")),
    ],
    targets: [
        .executableTarget(
            name: "WasmDemo",
            dependencies: [
                .product(name: "SwiftXState", package: "swift-xstate"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        )
    ]
)
