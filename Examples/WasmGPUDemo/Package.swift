// swift-tools-version: 6.2
import PackageDescription

// Experimental: GPU rendering in the browser, driven from Swift via WebAssembly.
// Swift → JavaScriptKit → WebGPU (Metal/Vulkan/D3D under the hood). A fullscreen fragment
// shader (WGSL authored in Swift) computes an animated pattern per pixel on the GPU.
//
// Build:  swift package --swift-sdk swift-6.3.2-RELEASE_wasm -c release js
// Needs a WebGPU-capable browser (Chrome/Edge 113+, Safari 18+, Firefox 141+).
let package = Package(
    name: "WasmGPUDemo",
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-webgpu", branch: "main"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.53.0")),
        .package(name: "swift-xstate", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "WasmGPUDemo",
            dependencies: [
                .product(name: "SwiftWebGPU", package: "swift-webgpu"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
                .product(name: "SwiftXState", package: "swift-xstate"),
            ]
        )
    ]
)
