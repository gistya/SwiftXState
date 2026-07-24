# WasmSwarm — parallel state management with Embedded Swift + Web Workers

A live field of simulated **embedded devices**, each running the *same* SwiftXState
"firmware" — a battery-aware behaviour state machine — compiled to a **329 KB
Embedded-Swift WebAssembly** module. The swarm is **sharded across Web Workers** (one
wasm instance per core), so the state of tens of thousands of devices is stepped in
parallel while the main thread renders the field.

It's a demo for two things this spike is about: letting **Swift devs do webdev with
known costs**, and giving **embedded devs a way to iterate on firmware at swarm scale
without hardware** — this is what your state machine looks like running on 64,000
devices at once, in a browser.

![swarm](.)  <!-- open dist/index.html to see it live -->

## The firmware (Brain.swift)

Each device is an independent instance of one machine:

```
patrol ─DETECT→ seek ─ARRIVE→ sample ─(battery full)→ patrol
  any  ─INTERFERE→ evade ─(timer)→ patrol
  any  ─(battery critical)→ sleep ─(recovered)→ patrol
```

Battery and the evade timer live in **context** (mutated by `assign` actions);
thresholds are `.inline` guards; beacon detection and the global interference are
events the shard engine sends from sensing. It's the reflection-free, Embedded-safe
config surface — the same firmware you'd flash to real hardware.

## Architecture

```
main thread                             each Web Worker (× cores)
──────────                              ─────────────────────────
• owns beacons + camera                 • its own wasm instance (own linear memory)
• each frame: post {beacons, subticks}  • spawnDevices(shard)  ← independent devices
  to every worker (parallel)            • tick(): sense → SwiftXState step → move
• collects render buffers (transfer)    • returns a packed [x,y,state] Float32 buffer
• draws all dots, batched by state
```

No shared memory — the parallelism is across **independent state machines**, which is
exactly what a fleet of devices is. (That's also why the wasm *threads* SDK isn't
needed here; see `../WasmEmbedded/bench/THREADS.md`.) Firmware is simulated faster than
it renders — `subticks` steps per frame — because real devices tick faster than a UI
repaints, and that's where the per-device state work lives.

## Parallel scaling (headless, honest)

`bench/swarm-scale.mjs` measures the workload with no rendering (the in-browser
frame-rate is only trustworthy when the tab is focused — browsers throttle background
tabs to ~1 fps, so don't benchmark there):

```
Node v26 · Apple M1 Max · 8,000 devices/shard · 8-byte context

 workers   devices   device-transitions/sec   scaling   per-core
 ----------------------------------------------------------------
    1        8,000                  382,905     1.00×     382,905
    2       16,000                  753,838     1.97×     376,919
    4       32,000                1,472,611     3.85×     368,153
    8       64,000                2,897,305     7.57×     362,163
   10       80,000                3,006,995     7.85×     300,699
```

Near-linear to **7.6× on 8 performance cores** (~2.9M device-transitions/sec stepping
**64,000 devices**), per-core holding ~370k until the cores saturate; 10 workers taper
(the 2 efficiency cores add little, and the main thread needs one). One core sustains
~383k device-transitions/sec of this firmware.

## vs the all-JS twin

`BrowserSwarm/` is the same swarm with the same interface, but every device is an
**XState v6 actor in JavaScript** instead of a SwiftXState machine in wasm. Head-to-head
(Apple M1 Max, device-transitions/sec): wasm **383k/core → 2.9M @ 8 cores (7.57× scaling)**
vs XState **183k/core → 631k @ 8 cores (3.45×)**; memory for 24,000 devices **4.5 MB**
(wasm) vs **1,850 MB** (XState) — **~410×**. XState wins engine size (94 KB min vs 329 KB).
Full table + caveats in [BrowserSwarm/README.md](BrowserSwarm/README.md).

## Build & run

Requires the `swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a` toolchain + its
`…wasip1-embedded` SDK.

```sh
./build.sh                          # → dist/index.html (self-contained) + dist/WasmSwarm.wasm
node web/smoke.mjs                  # headless ABI test (spawn/tick/interfere)
node bench/swarm-scale.mjs 8000 200 4   # the scaling table above
```

Open `dist/index.html` (served, so the Web Workers' Blob URL isn't blocked by
`file://`). Controls: **Workers**, **Devices**, **Firmware ticks/frame**, and **Inject
interference** (watch the whole swarm flip to `evade` and scatter). Drop Workers to 1
at a heavy load to saturate a core, then raise it — the frame-rate scales with cores.

## Layout

```
Sources/WasmSwarm/
  Brain.swift    the firmware FSM (states, guards, assign, contextFromInput battery)
  Swarm.swift    one shard: devices, beacon sensing, kinematics, the tick loop
  Bridge.swift   reactor ABI: spawnDevices / setBeacons / tick + alloc/dealloc
  main.swift     empty (reactor)
web/
  index.html.template   main-thread canvas + dashboard + the inline worker
  loader.js             WASI shim + reactor instantiate (shared with the worker)
  smoke.mjs             headless ABI test
bench/
  swarm-scale.mjs       worker-threads scaling benchmark
```
