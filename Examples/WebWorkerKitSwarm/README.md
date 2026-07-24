# WebWorkerKitSwarm — an interactive SwiftXState control room over `distributed actor`s

Two SwiftXState machines, each running inside **its own Web Worker** (a separate OS
thread) as a Swift **`distributed actor`**, driven by a live browser UI. Every button is a
real cross-worker call; the event names and the returned snapshot travel as **Codable**
(WebWorkerKit — message-passing, no shared memory). Built and verified on the 2026-07-11
snapshot.

This is the distributed-actors counterpart to `../WebWorkerExecutor` (which put SwiftXState
actors on *shared-memory* worker threads).

## What it shows — click it

Open the page and you get a control room with three panels:

- **CounterWorker (Worker #1)** — a bounded `[0, 10]` counter. `+ INC` / `− DEC` / `RESET`
  make distributed calls; the value, the fill meter, and the state pill update from the
  returned report. The buttons **disable themselves at the guards** — `−` greys out at 0,
  `+` greys out at 10 — because the worker reports *which events are currently legal*
  (see `enabled` below), not because the UI re-encodes the guards.
- **TrafficWorker (Worker #2)** — a `red → green → yellow → red` light. `NEXT` advances the
  state (the right bulb lights up); a full lap bumps a `cycles` counter. A pedestrian
  **`WALK`** exists *only on red*, so that button lights up exactly when the machine allows
  it. This is a genuinely separate worker — a second distributed-actor type is a second OS
  thread.
- **Two threads, for real** — run the same CPU burn on both workers. Sequentially it costs
  ~2× the time; in parallel the two workers overlap on two cores. Measured live in-browser:
  **`sequential 317 ms · parallel 142 ms · ≈ 2.2× faster`**. The spinner keeps turning the
  whole time — proof the UI thread is never blocked, because the work is off on the workers.

A wire log at the bottom traces every crossing, e.g.:

```
→ counter.send(INC)   ⇒  value=10  enabled=["DEC", "RESET"]     # INC dropped itself at the ceiling
→ traffic.send(NEXT)  ⇒  yellow  cycles=0 walks=0
→ traffic.send(WALK)  ⇒  red  cycles=1 walks=1
⚙︎ sequential burn: 317 ms
⚙︎ parallel burn: 142 ms
```

## Design — a transport-agnostic library + thin WebWorkerKit actors

Two targets, as you'd ship it:

- **`SwiftXStateDistributed`** (library) — depends only on **SwiftXState + Codable**, no
  WebWorkerKit. The reusable piece: `MachineHost<Context>` owns a machine + its snapshot and
  steps it via the pure reducer; `MachineReport<Context>` is the Codable value that crosses
  the wire. It carries **`state`, `context`, `done`, and `enabled`** — the subset of the
  machine's event vocabulary that is sendable *right now* (guards satisfied). That last field
  is what lets a remote UI render guard-aware controls without duplicating the machine's
  logic: the worker is the single source of truth for what's legal. Because it's
  transport-agnostic, the same host works with any `DistributedActorSystem` (Web Workers,
  XPC, gRPC…).
- **`App`** (demo) — two `distributed actor … : WebWorker` types (`CounterWorker`,
  `TrafficWorker`), each holding a `MachineHost` and exposing `distributed func send/report`
  (plus a `busy` used only by the parallelism panel). WebWorkerKit spawns each in its own
  worker; the main thread builds the UI (`UI.swift`) and calls them.

```swift
distributed actor CounterWorker: WebWorker {
    private let host = MachineHost(makeCounter())        // machine lives in the worker
    distributed func send(_ event: String) -> MachineReport<CounterContext> { host.send(event) }
    distributed func report() -> MachineReport<CounterContext> { host.report() }
}
```

## Extending the DSL to this

`MachineHost.init` takes a `ResolvedMachine<Context>` — and **both** authoring surfaces
produce one: `createMachine(MachineConfig(...))` (used here) *and* the Plan D DSL
(`StateMachine.resolvedMachine(id:)`). So the DSL composes with distribution **for free** —
author the machine with the DSL, hand it to a `MachineHost`, wrap that in a distributed
actor. The one thing that stays hand-written is the `distributed actor` declaration itself:
generating it from a DSL spec would need a macro, which Plan D bars — so the clean seam is
"DSL authors the machine; the actor is a ~6-line wrapper."

## vs the other multithreading demos

| | this (WebWorkerKit) | WebWorkerExecutor | WasmSwarm |
|---|---|---|---|
| model | `distributed actor`, **message-passing** (Codable) | shared-memory worker threads | N isolated wasm instances |
| transport | Codable across `postMessage` | shared linear memory | copies across `postMessage` |
| threads SDK | not needed | required (SharedArrayBuffer) | not needed |
| best for | typed, isolated services per worker | one machine's state shared across threads | huge fleets of independent machines |

## Build & run

Requires the `swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a` toolchain, its full-stdlib `wasip1`
SDK, Node, and network (WebWorkerKit + JavaScriptKit + the JS runtime dep).

```sh
./build.sh
(cd Bundle && python3 -m http.server 8778)   # then open http://localhost:8778/
```

Integration notes that cost time (kept so the next person doesn't pay them):
- **JavaScriptKit 0.56.1** (not 0.53) is the version that compiles under the 6.5-dev
  snapshot; WebWorkerKit `main` compiles against it fine.
- **`--build-system native`** for the PackageToJS build.
- The browser can't resolve the bare `@bjorn3/browser_wasi_shim` specifier PackageToJS
  emits — **esbuild-bundle** `index.js` (build.sh does it).
- WebWorkerKit's worker-context check is `importScripts`, which exists only in **classic**
  workers — so `isModule = false` and the worker entry is a classic script that `import()`s
  the ES-module bundle. And `scriptPath` **must** be set (the `nil` default resolves to the
  `.wasm` module path under WASI, which isn't a Worker script).
- WebWorkerKit allows **one instance per `WebWorker` type** (a documented limitation) — which
  is exactly why the two machines are two *types* (`CounterWorker`, `TrafficWorker`): two
  types → two workers. A larger swarm = one distributed-actor type per shard, or the
  shared-memory `../WebWorkerExecutor` route.
- Reaching `document.body` from Swift: read it through a `JSObject` (`document.object!.body`),
  because a bare `.body` dynamic-member read on a `JSValue` is ambiguous.
