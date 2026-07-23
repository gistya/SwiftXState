# WebWorkerKitSwarm — SwiftXState machines as `distributed actor`s

The distributed-actors counterpart to `../WebWorkerExecutor`. Where that put SwiftXState
actors on **shared-memory** worker threads, this runs a SwiftXState machine inside its
own Web Worker as a Swift **`distributed actor`**, with **Codable** message transport
across the worker boundary (WebWorkerKit). Verified live in the browser on the
2026-07-11 snapshot.

## What it shows

```
spawning CounterWorker — a SwiftXState machine in its own Web Worker…
  initial: state=counting value=0
  INC #1 → value=1  …  INC #7 → value=7
  DEC   → value=6
  RESET → value=0
done — the machine stepped inside the worker; every event + report crossed as Codable.
```

The machine (its guards, its assign actions, its live snapshot) runs entirely in the
worker; the main thread only sends event names and receives a Codable `MachineReport`.

## Design — a transport-agnostic library + a thin WebWorkerKit actor

Two targets, as you'd ship it:

- **`SwiftXStateDistributed`** (library) — depends only on **SwiftXState + Codable**, no
  WebWorkerKit. It's the reusable piece: `MachineHost<Context>` owns a machine + its
  snapshot and steps it via the pure reducer; `MachineReport<Context>` is the Codable
  value that crosses the wire. Because it's transport-agnostic, the same host works with
  any `DistributedActorSystem` (Web Workers, XPC, gRPC…) or any RPC.
- **`App`** (demo) — a `distributed actor CounterWorker: WebWorker` that holds a
  `MachineHost` and exposes `distributed func send/report`. WebWorkerKit spawns it in a
  worker; the main thread calls it.

```swift
distributed actor CounterWorker: WebWorker {
    private let host = MachineHost(makeCounter())   // machine lives in the worker
    distributed func send(_ event: String) -> MachineReport<CounterContext> { host.send(event) }
    distributed func report() -> MachineReport<CounterContext> { host.report() }
}
```

## Extending the DSL to this

`MachineHost.init` takes a `ResolvedMachine<Context>` — and **both** authoring surfaces
produce one: `createMachine(MachineConfig(...))` (used here) *and* the Plan D DSL
(`StateMachine.resolvedMachine(id:)`). So the DSL composes with distribution **for
free** — author the machine with the DSL, hand it to a `MachineHost`, wrap that in a
distributed actor. The one thing that stays hand-written is the `distributed actor`
declaration itself: generating it from a DSL spec would need a macro, which Plan D bars —
so the clean seam is "DSL authors the machine; the actor is a 6-line wrapper."

## vs the other multithreading demos

| | this (WebWorkerKit) | WebWorkerExecutor | WasmSwarm |
|---|---|---|---|
| model | `distributed actor`, **message-passing** (Codable) | shared-memory worker threads | N isolated wasm instances |
| transport | Codable across `postMessage` | shared linear memory | copies across `postMessage` |
| threads SDK | not needed | required (SharedArrayBuffer) | not needed |
| best for | typed, isolated services per worker | one machine's state shared across threads | huge fleets of independent machines |

It's the Swift-native, type-checked version of "shard actors across workers" — the same
idea as the swarm's manual `postMessage`, but as real `distributed actor` calls.

## Build & run

Requires the `swift-DEVELOPMENT-SNAPSHOT-2026-07-11-a` toolchain, its full-stdlib
`wasip1` SDK, Node, and network (WebWorkerKit + JavaScriptKit + the JS runtime dep).

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
  workers — so `isModule = false` and the worker entry is a classic script that
  `import()`s the ES-module bundle. And `scriptPath` **must** be set (the `nil` default
  resolves to the `.wasm` module path under WASI, which isn't a Worker script).
- WebWorkerKit currently allows **one instance per `WebWorker` type** (a documented
  limitation); a larger swarm = one distributed-actor type per shard, or the
  shared-memory `../WebWorkerExecutor` route.
