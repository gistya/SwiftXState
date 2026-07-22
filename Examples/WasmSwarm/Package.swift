// swift-tools-version: 6.1
import PackageDescription

// WasmSwarm — thousands of simulated embedded devices, each running the SAME
// SwiftXState "firmware" (a battery-aware forage/patrol behavior state machine),
// compiled to Embedded-Swift WebAssembly. One wasm instance runs a SHARD of the
// swarm; the browser spreads shards across Web Workers (one instance per core) and
// renders the combined field. See README.md.
//
// Built via ./build.sh (Embedded, reactor, Unicode data tables) — same recipe as
// Examples/WasmEmbedded.
let package = Package(
    name: "WasmSwarm",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "WasmSwarm", targets: ["WasmSwarm"]),
    ],
    dependencies: [
        .package(name: "SwiftXState", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "WasmSwarm",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
            ],
            path: "Sources/WasmSwarm",
            linkerSettings: [
                .unsafeFlags([
                    "-Xclang-linker", "-mexec-model=reactor",
                    "-Xlinker", "--strip-all",
                    "-Xlinker", "--export-if-defined=alloc",
                    "-Xlinker", "--export-if-defined=dealloc",
                    "-Xlinker", "--export-if-defined=spawnDevices",
                    "-Xlinker", "--export-if-defined=setBeacons",
                    "-Xlinker", "--export-if-defined=tick",
                    "-Xlinker", "--export-if-defined=lastTickSteps",
                ], .when(platforms: [.wasi])),
            ]
        ),
    ]
)
