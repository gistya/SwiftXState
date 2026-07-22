# WasmEmbedded — SwiftXState on Embedded Swift + WebAssembly

A single, self-contained `index.html` that runs **real SwiftXState machines** entirely
in the browser, from an **Embedded Swift** WebAssembly module (~650 KB) inlined as
base64. No server, no JavaScript framework, no Foundation.

![five machines: Toggle, Traffic Light, Vending Machine, Bounded Counter, Pedestrian Crossing](.)

## What it demonstrates

Five machines exercising the core feature surface — all driven from JS through a tiny
JSON-in / JSON-out reactor ABI:

| Machine | Shows |
|---|---|
| **Toggle** | two states + an `assign` action bumping a context counter |
| **Traffic Light** | a cycle (`green→yellow→red→green`), lap counting, a `PANIC` shortcut |
| **Vending Machine** | a **guard** — `DISPENSE` only fires once `credits ≥ 3` — plus multiple assigns |
| **Bounded Counter** | guards both ways (clamped to `[0, 10]`) via action-only internal transitions |
| **Pedestrian Crossing** | a **compound** state — `red` nests `walk`/`dontWalk` (state value reads `red.walk`) |

## The key idea

Embedded Swift can't provide `Codable` or reflection, which rules out SwiftXState's
async `Actor` runtime and its snapshot/persistence layer. But the machine itself is a
**pure synchronous reducer**:

```swift
let logic = MachineLogic(machine: createMachine(MachineConfig(...)))
var snap  = logic.initialState(input: nil)      // MachineSnapshot<Context>
snap      = logic.step(snap, on: Event("COIN")) // pure — no async, no Codable
```

Drive `step` in a loop and you get the full engine — states, guards, `assign`, compound
states — with none of the Embedded-hostile machinery. This sample authors machines with
the string-keyed config API (the reflection-free surface) and closure-form `assign` /
`.inline` guards only.

## Build

Requires the `swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a` toolchain and its
`…-wasm32-unknown-wasip1-embedded` Swift SDK (installed via `swift sdk install`).

```sh
./build.sh
```

Outputs `dist/index.html` (open it directly) and `dist/WasmXStateDemo.wasm`.

The script cross-compiles the core in whole-program Embedded mode
(`-enable-experimental-feature Embedded -wmo`), links `libswiftUnicodeDataTables.a`
(String-keyed `Dictionary` support), builds a wasm **reactor**
(`-mexec-model=reactor`, so the host calls `_initialize` once), and inlines the base64
wasm + loader into the HTML template.

## Verify

```sh
node web/smoke.mjs dist/WasmXStateDemo.wasm   # 30 headless assertions over the ABI
```

## ABI

The module exports three reactor functions; the host speaks length-prefixed UTF-8 JSON:

- `alloc(len) -> ptr`
- `dealloc(ptr, len)`
- `query(ptr, len) -> resPtr` — one JSON request → a `[u32 length][utf8]` result buffer

Ops: `catalog`, `reset {machine}`, `send {machine, event}`, `snapshot {machine}`.

## Layout

```
Sources/WasmXStateDemo/
  Machines.swift   the 5 machines + a type-erased MachineSession registry
  Engine.swift     JSON dispatch over the session registry (core JSONValue, no Foundation)
  Bridge.swift     alloc / dealloc / query reactor exports
  main.swift       intentionally empty (reactor: main() never runs)
web/
  loader.js        WASI shim + reactor ABI wrapper (shared by the browser + smoke test)
  index.html.template   the UI; build.sh fills in the base64 wasm + loader
  smoke.mjs        headless Node conformance test
```
