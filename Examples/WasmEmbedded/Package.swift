// swift-tools-version: 6.1
import PackageDescription

// WasmXStateDemo — SwiftXState compiled to a tiny, self-contained *Embedded* Swift
// WebAssembly module. It drives real SwiftXState machines through the synchronous
// reducer path (`MachineLogic.initialState` / `.step`), so it needs neither the
// async `Actor` runtime nor the `Codable` persistence layer — the two things that
// otherwise pull Embedded Swift off the table.
//
// Built via ./build.sh, NOT plain `swift build`: the script supplies the wasm SDK,
// the whole-program `-enable-experimental-feature Embedded` + `-wmo` flags (so the
// SwiftXState + CompositionalInit dependencies are compiled in Embedded mode too),
// and links libswiftUnicodeDataTables.a (String-keyed Dictionary support). The
// reactor/export linker flags below are gated to wasi so a native `swift build`
// (for quick API sanity checks) still links with the host linker.
let package = Package(
    name: "WasmXStateDemo",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "WasmXStateDemo", targets: ["WasmXStateDemo"]),
    ],
    dependencies: [
        // The SwiftXState under development, consumed by local path.
        .package(name: "SwiftXState", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "WasmXStateDemo",
            dependencies: [
                .product(name: "SwiftXState", package: "SwiftXState"),
            ],
            path: "Sources/WasmXStateDemo",
            linkerSettings: [
                .unsafeFlags([
                    // Reactor model: emit `_initialize` (runs global ctors) instead of
                    // `_start`. The host calls it once after instantiation.
                    "-Xclang-linker", "-mexec-model=reactor",
                    // Strip DWARF + symbol names (SwiftPM adds -g even in release). The
                    // wasm is base64-embedded into the HTML, so size matters.
                    "-Xlinker", "--strip-all",
                    // Keep the reactor's exported entry points.
                    "-Xlinker", "--export-if-defined=alloc",
                    "-Xlinker", "--export-if-defined=dealloc",
                    "-Xlinker", "--export-if-defined=query",
                    "-Xlinker", "--export-if-defined=benchRun",
                ], .when(platforms: [.wasi])),
            ]
        ),
    ]
)
