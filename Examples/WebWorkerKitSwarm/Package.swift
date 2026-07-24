// swift-tools-version: 6.1
import PackageDescription

// WebWorkerKitSwarm — SwiftXState machines running inside `distributed actor`s over
// Web Workers, with Codable message transport (WebWorkerKit). Two targets:
//
//   • SwiftXStateDistributed — a small, TRANSPORT-AGNOSTIC library: run a SwiftXState
//     machine behind a Codable request/response boundary (a `MachineHost` + a Codable
//     `MachineReport`). Depends only on SwiftXState + Codable — no WebWorkerKit — so it
//     works with any DistributedActorSystem (or any RPC).
//   • App — the demo: wraps that host in a WebWorkerKit `distributed actor` and drives
//     it from the main JS context. Built for full-stdlib wasip1-threads via PackageToJS.
let package = Package(
    name: "WebWorkerKitSwarm",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwiftXStateDistributed", targets: ["SwiftXStateDistributed"]),
        .executable(name: "App", targets: ["App"]),
    ],
    dependencies: [
        .package(name: "SwiftXState", path: "../.."),
        .package(url: "https://github.com/swiftwasm/WebWorkerKit", branch: "main"),
        // Force the JavaScriptKit that compiles under the 2026-07-11 snapshot (WebWorkerKit
        // only requires `from 0.16.0`, which would otherwise still resolve here — pinned for clarity).
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.56.1")),
    ],
    targets: [
        .target(
            name: "SwiftXStateDistributed",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "SwiftXStateCodable", package: "SwiftXState"),
            ],
            path: "Sources/SwiftXStateDistributed"
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                "SwiftXStateDistributed",
                .product(name: "WebWorkerKit", package: "WebWorkerKit"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ],
            path: "Sources/App"
        ),
    ]
)
