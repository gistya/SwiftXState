// swift-tools-version: 6.1
import PackageDescription

// WasmSwarmLite — a "lite" communicating swarm: ONE full-stdlib wasm instance (no Web
// Workers) hosting many SwiftXState node actors that talk to each other THROUGH a router
// actor, using the framework's real spawn + sendToParent/sendTo delivery. Rendered live on a
// 2-D canvas via JavaScriptKit. Built for wasip1 via PackageToJS (see build.sh).
let package = Package(
    name: "WasmSwarmLite",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"]),
    ],
    dependencies: [
        .package(name: "SwiftXState", path: "../.."),
        // The JavaScriptKit that compiles under the 2026-07-11 snapshot (see the sibling
        // WebWorkerKit example for why 0.56.1 specifically).
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", .upToNextMinor(from: "0.56.1")),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ],
            path: "Sources/App"
        ),
    ]
)
