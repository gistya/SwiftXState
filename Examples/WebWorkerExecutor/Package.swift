// swift-tools-version: 6.1
import PackageDescription

// WebWorkerExecutor — does JavaScriptKit's WebWorkerTaskExecutor give SwiftXState's
// async Actor real multi-threading on wasm? On wasm the Actor is a *default* actor
// (its custom ActorSerialExecutor is `#if canImport(Darwin)` only), so it should honor
// a task-executor preference and run on Web Worker threads. Built with the 2026-07-11
// snapshot + the full-stdlib wasip1-threads SDK via JavaScriptKit's PackageToJS plugin.
let package = Package(
    name: "WebWorkerExecutor",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "SwiftXState", path: "../.."),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.56.1")),
    ],
    targets: [
        .executableTarget(
            name: "WebWorkerExecutor",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ]
        ),
    ]
)
