![SwiftXState Logo](Assets/swiftxstate_logo.png)

# SwiftXState

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**XState-compatible state machines and actors for Swift — built from the ground up to run wherever Swift runs: Apple platforms, Linux, and Windows.**

SwiftXState is a Swift implementation of the [XState](https://github.com/statelyai/xstate) actor and state-machine model. It follows the same mental model, event protocol, and inspector wire format as XState v5, but it is not a transpiler and it does not wrap the JavaScript XState library (for example via JavaScriptCore or a Node FFI bridge). The **interpreter itself** is written in idiomatic Swift with `Sendable` types and structured concurrency — no UI framework dependencies in the core runtime.

That is separate from how **your app** uses Swift. Swift has excellent C and C++ interop (`import`ing C modules, Swift 5.9+ C++ interop, Objective-C bridges, `fromCallback` / `fromTask` invoke children). SwiftXState is meant to sit *on top of* that stack: the state machine orchestrates behavior in Swift, while invoked actors and actions call into native libraries at the edges. The goal is not just parity with JavaScript — it is extending the architecture into compiled mobile and desktop apps, offline-first persistence, deterministic replay, and structured `async`/`await` workflows alongside existing C/C++ codebases.

---

## Acknowledgments

SwiftXState would not exist without the work of **[Stately](https://stately.ai)** and the **[XState](https://github.com/statelyai/xstate)** team.

XState's open-source design, documentation, inspector protocol, and machine-definition shape are the foundation this project builds on. Stately's decision to publish `@statelyai/inspect`, document the wire format, and keep the core model approachable is exactly what makes a native Swift reimplementation possible — and legitimate.

Thank you to David Khourshid and everyone who has contributed to XState and the Stately ecosystem. This project is a complement, not a replacement: we want Swift developers to speak the same state-machine language as the web, while leaning into what Swift does best.

---

## Packages

| Module | Purpose |
|--------|---------|
| **SwiftXState** | Core runtime — machines, actors, transitions, guards, actions, invoke/spawn, persistence, replay |
| **SwiftXStateSwiftUI** | `useMachine`, `useSelector`, `useMapState`, `@MachineState` — mirrors `@xstate/react` patterns |
| **SwiftXStateInspect** | Inspection events + Stately wire converter + file/mock transports |
| **SwiftXStateInspectURLSession** | WebSocket transport for live Stately Inspector sessions |
| **SwiftXStateSwiftData** | SwiftData-backed actor snapshot and replay session storage (Apple only) |
| **SwiftXStateGraph** | Live statechart visualizer: GPU-backed SwiftUI `Canvas` (2D) + SceneKit (3D layers), with nested regions, real-time active-state highlighting, zoom/pan/drag, and full theming via `GraphStyle` |
| **SwiftXStateInspectorUI** | Native Stately-Inspector-parity panel over the in-process `InspectionEvent` stream: selectable actor list, live graph per actor, expandable JSON state/context trees, event feed, and sequence diagram. Handles many actors (96-actor stress test) where the web inspector stalls. Also **imports XState machine-definition JSON** (`MachineDefinitionImporter`) and **structurally simulates** pasted machines (`MachineSimulator`) for click-through stepping. Themeable via `InspectorStyle` |

**Swift:** 6.2+ with strict concurrency enabled on core targets

### Platform support

| Platform | SwiftXState | SwiftXStateInspect | SwiftXStateInspectURLSession | SwiftXStateSwiftUI | SwiftXStateSwiftData |
|----------|-------------|--------------------|------------------------------|--------------------|-----------------------|
| macOS 14+ | Supported | Supported | Supported (URLSession WebSocket) | Supported | Supported |
| iOS / tvOS / watchOS | Supported | Supported | Supported | Supported | Supported |
| Linux | Supported | Supported | Stub only — inject custom transport | N/A | N/A |
| Windows 10+ | Supported | Supported | Stub only — inject custom transport | N/A | N/A |

The **core** (`SwiftXState`, `SwiftXStateInspect`) uses Foundation and structured concurrency only — no AppKit/UIKit/SwiftUI in those modules — so Linux and Windows builds are expected to work for server/CLI use. Apple-only modules (`SwiftXStateSwiftUI`, `SwiftXStateSwiftData`, URLSession WebSocket inspect) compile as stubs elsewhere. Linux/x86_64 CI verification is planned; if you hit a platform issue, please file it. Community contributions for alternative bindings (e.g. GTK, Qt, file/SQLite persistence) are welcome.

**Custom inspect networking on Linux/Windows:** implement `InspectTransport` yourself, or use `ClosureInspectTransport` / `TextPublishInspectSession` from `SwiftXStateInspect` with your WebSocket client. See `CustomInspectTransport.swift` for a full example.

**3D graph view & visionOS:** the 3D graph renderer (`SwiftXStateGraph`) is built on SceneKit and runs on macOS/iOS/tvOS. In this initial release it does **not** support visionOS / spatial (augmented-reality) features — there is no Vision Pro spatial scene or AR anchoring yet. A RealityKit-based backend for visionOS is something we're investigating; the renderer is isolated behind `StateGraphView`, so a spatial backend can be added without affecting the model, layout, or 2D paths.

### Quick start

```swift
import SwiftXState

let toggle = createMachine(MachineConfig(
    id: "toggle",
    initial: "inactive",
    context: EmptyContext(),
    states: [
        "inactive": StateNodeConfig(on: ["toggle": .to("active")]),
        "active": StateNodeConfig(on: ["toggle": .to("inactive")]),
    ]
))

let actor = createActor(toggle).start()
actor.send(Event("toggle"))
print(actor.snapshot.matches("active")) // true
```

For SwiftUI, see `SwiftXStateSwiftUI` (`useMachine`, `useSelector`, `useMapState`). For a full app-shaped example, see [Examples/SwiftXChess](Examples/SwiftXChess/README.md).

**Paths & model-based testing** (`@xstate/graph` parity, core / cross-platform):

```swift
let model = TestModel(toggle)

for path in model.shortestPaths() {
    print(path.description) // e.g. "-toggle-> active"
    try model.test(
        path,
        onState: { snapshot in /* assert your UI matches snapshot.value */ },
        onEvent: { event in   /* drive your component with event */ }
    )
}

// Static checks over the reachable graph:
for issue in model.validate() {
    print(issue.kind, issue.stateKey) // .deadEnd / .unreachableState
}
```

Also available as free functions: `getAdjacencyMap`, `getShortestPaths`, `getSimplePaths`, `validate`. Tune traversal with `TraversalOptions` (custom event resolver, state serialization, `maxStates`).

### Two authoring tiers

SwiftXState offers the same machine two ways — pick per file, mix freely. Both compile to the **same** machine, the **same** `definitionJSON()`, and the **same** inspector stream, so interop with Stately/XState tooling is identical either way.

**Tier 1 — XState-familiar** (string keys; reads almost line-for-line like XState):

```swift
StateNodeConfig(on: [
    "input.focus":  .to("active"),
    "input.change": .single(TransitionConfig(target: "debouncing")),
])
```

**Tier 2 — Swift-native, opt-in** (each event is its own type; guard/action closures receive the **concrete, narrowed event** — no cast, no `assertEvent`):

```swift
struct InputChange: StateEvent { static let eventType = "input.change"; let searchInput: String }

StateNodeConfig(on: transitions(
    on(Focus.self, target: "active"),
    on(InputChange.self, target: "debouncing",
       actions: [assign { (ctx: inout Ctx, e: InputChange) in ctx.searchInput = e.searchInput }])
))

actor.send(InputChange(searchInput: "be"))   // typed at the call site
```

**Compile-checked targets** — `@MachineStates` generates a `StateName` enum *from the machine's own declarations*, so targets are autocompleted, rename-safe, and can never drift:

```swift
@MachineStates("AppState")
let config = MachineConfig(id: "app", initial: "idle", context: Ctx(), states: [
    "idle":    StateNodeConfig(on: transitions(on(Focus.self, to: AppState.active))),
    "active":  StateNodeConfig(states: ["fast": StateNodeConfig(), "slow": StateNodeConfig()]),
])
// generates: enum AppState: String, StateName { case idle; case active; case activeFast = "active.fast"; … }
// AppState.activeFast → "#active.fast"  (absolute target, resolves regardless of nesting)
```

### XState → SwiftXState (Rosetta)

| XState (TS) | SwiftXState |
|-------------|-------------|
| `createMachine({ … })` | `createMachine(MachineConfig(…))` |
| `setup({ actions, guards, delays, actors })` | `setup(actions:guards:delays:actors:)` |
| `setup({ types: { events, context } })` | typed `Context` generic + Tier-2 `StateEvent` types |
| `on: { EVENT: 'target' }` | `on: ["EVENT": .to("target")]` (Tier 1) / `on(EventType.self, target: "target")` (Tier 2) |
| `target: 'someState'` (string) | `to: AppState.someState` — compile-checked via `@MachineStates` |
| `assign({ x: ({ event }) => … })` | `assign { (ctx: inout C, e: EventType) in ctx.x = … }` (Tier 2) |
| `assertEvent(event, "…")` | not needed — the Tier-2 handler is already typed to the event |
| `guard: 'name'` / `({ context, event }) => …` | `guard: .named("name")` / `guarded { (c, e: EventType) in … }` |
| `always`, `after`, `invoke`, `spawn`, `raise`, `sendTo`, tags, `meta` | same names, same model |

---

## Included Sample Apps

### SwiftXInspector App

Write or paste your XState JSON and run your state machines in high-performance SwiftXStateGraph 2D or 3D views, on-device (Inspector has only been tested so far on macOS).

![SwiftXInspector Screenshot](Assets/LocalInspector.png)

### SwiftXChess

An example chess game implemented in SwiftUI and SwiftXState, showing the power of the GPU-accelerated SwiftXStateGraph rendering engine with one window for the app and one window for the inspector, performant even with 897 nodes and 1,536 transitions. 

![SwiftXChess Screenshot](Assets/SwiftXChess.png)

This sample app illustrates the advantages of SwiftUI and Metal. Apple Silicon allows SwiftXState to graphically render realtime behavior on large, complex state charts. 

![ChessNode](Assets/ChessNodes.png)

## Parity with XState

The table below summarizes where SwiftXState stands today relative to **XState v5** and the broader Stately ecosystem. Status meanings:

- **✅ Parity** — implemented and tested
- **🔶 Partial** — works for common cases; known gaps listed
- **➕ SwiftXState only** — not in stock XState (or not in the same form)
- **📋 Planned** — intended; not implemented yet
- **➖ N/A** — platform or ecosystem difference, not a goal for native Swift

### Core state machines

| Capability | Status | Notes |
|------------|--------|-------|
| `createMachine` / `setup().createMachine()` | ✅ Parity | `MachineConfig`, `StateNodeConfig` mirror XState config |
| State types (atomic, compound, parallel, final, history) | ✅ Parity | Shallow and deep history |
| Events (`Eventable`, `Event("TAP")`, string shorthand) | ✅ Parity | Custom `Eventable` types supported (see SwiftXChess) |
| Wildcard transitions (`*`, `prefix.*`) | ✅ Parity | |
| Guards (named, inline, `and` / `or` / `not`, `stateIn`) | ✅ Parity | |
| Parameterized guards `{ type, params }` | ✅ Parity | `guardRef(_:params:)`, `dynamicGuard`, `setup().registerGuard` |
| Actions (assign, raise, sendTo, spawn, stop, log, emit, …) | ✅ Parity | |
| `enqueueActions` | ✅ Parity | |
| `always` transitions | ✅ Parity | |
| `after` delayed transitions | ✅ Parity | Named delays via `setup(delays:)` |
| Internal transitions (actions only, no target) | ✅ Parity | |
| `reenter` | ✅ Parity | |
| Parallel regions + multi-target transitions | ✅ Parity | |
| Tags + `snapshot.hasTag(_:)` | ✅ Parity | |
| State `meta` on config | ✅ Parity | `StateNodeConfig.meta` + `snapshot.getMeta()` |
| Final state `output` + `status: done` | ✅ Parity | |
| `xstate.done.state.{id}` (nested final completion) | ✅ Parity | `StateNodeConfig.onDone` + `DoneStateEvent` |
| Pure `transition()` / `initialTransition()` | ✅ Parity | Side effects not run in pure path |
| `waitFor` | ✅ Parity | |
| `SimulatedClock` | ✅ Parity | Deterministic delays in tests |

### Actors and invoke

| Capability | Status | Notes |
|------------|--------|-------|
| `createActor` + mailbox + `send` | ✅ Parity | See [Concurrency](#concurrency-swiftxstate-actor-vs-swift-actor) |
| `invoke` / `spawnChild` | ✅ Parity | |
| `fromMachine` (child state machines) | ✅ Parity | |
| `fromTask` (`fromPromise`) | ✅ Parity | `async throws` with structured scope |
| `fromCallback` | ✅ Parity | Long-running listeners + cleanup |
| `fromTransition` | ✅ Parity | |
| `fromObservable` / `Subscribable` | ✅ Parity | |
| `fromStore` | ✅ Parity | XState store actor logic |
| `fromTaskGroup` | ➕ SwiftXState only | Structured concurrent child work via `TaskGroup` |
| `sendBack` in callback actors | ✅ Parity | `CallbackActorScope.sendBack` — alias for `sendToParent` |
| `ActorSystem` (register, get, inspect) | ✅ Parity | |
| `forwardTo`, `sendTo` (with delay), `sendParent` | ✅ Parity | |
| `emit` + `actor.on("eventType")` | ✅ Parity | |

### Persistence and replay

| Capability | Status | Notes |
|------------|--------|-------|
| `getPersistedSnapshot` / `restoreSnapshot` | ✅ Parity | Requires `Codable` context |
| `actor.start(from:)` hydration | ✅ Parity | Two-step: `createActor` then `start(from:)` |
| `createActor(..., snapshot:)` one-shot hydration | ✅ Parity | Already started; `ActorPersistenceStore.createActor(_:key:)` for SwiftData |
| Child actor state in persisted snapshots | ✅ Parity | **Machine** children round-trip recursively; opaque children persist status only — use `onCancel` + `opaqueRestorePolicy` for SwiftData cleanup / deferred re-spawn |
| **Replay sessions** (record, pure replay, scrub) | ➕ SwiftXState only | `ReplaySession`, `RecordedStep`, `ReplayDriver` |
| Replay with full custom event payloads | ✅ Parity | `ReplayPayloadRepresentable`, `PayloadEvent`, `ReplayEventDecoder` |
| **SwiftData persistence** | ➕ SwiftXState only | `ActorPersistenceStore`, `ReplayPersistenceStore` |

### Inspector and tooling

| Capability | Status | Notes |
|------------|--------|-------|
| Inspection protocol (`@xstate.*` events) | ✅ Parity | |
| Stately wire format + `@statelyai/inspect` | ✅ Parity | `StatelyWireConverter`, WebSocket transport |
| `definitionJSON()` export | ✅ Parity | Stately-compatible machine graphs |
| Machine JSON **import** | 🔶 Partial | Load any XState machine-definition JSON into the inspector (`MachineDefinitionImporter` / `InspectorStore.loadDefinition`): renders the graph and reconstructs the initial state value + `context`. A **structural simulator** (`MachineSimulator`) then lets you click through `on` / `always` / `after` / `invoke.onDone` transitions, with synthetic event + snapshot rows feeding the Events/Sequence tabs. Control-flow only — guards aren't evaluated and actions/`assign`/actors don't run (those are code, not data). See [`Examples/InspectorPasteApp`](Examples/InspectorPasteApp/). Full round-trip back to `definitionJSON()` is still planned. |
| `meta` in exported definitions | ✅ Parity | |
| `@xstate/graph` (paths, TestModel, validation) | ✅ Parity | **Core**, cross-platform (Linux too): `getAdjacencyMap`, `getShortestPaths`, `getSimplePaths`, `TestModel` (model-based path testing via `test(_:onState:onEvent:)`), and `validate` (dead-end + unreachable-state checks). Built on the faithful pure `transition` (guards evaluated, `assign` applied), with `TraversalOptions` for custom event resolvers / state serialization. **Note:** this is the algorithm layer — distinct from the like-named `SwiftXStateGraph` *visualizer* module (same collision exists in XState). |
| Native SwiftUI visualizer | ✅ | `SwiftXStateGraph` library: GPU-backed `Canvas` 2D renderer + SceneKit 3D mode, walks the real machine tree (nested compound/parallel regions, transitions, initial/final markers), live active-state highlighting, anchored zoom / pan / node-drag (+ mouse-wheel on macOS), themeable via `GraphStyle`. |
| Browser `__xstate__` devtools hook | ➖ N/A | Stately inspect covers cross-platform debugging |

### Type safety and DX

| Capability | Status | Notes |
|------------|--------|-------|
| `setup(actions:guards:delays:actors:)` | ✅ Parity | |
| `setup({ types: { events, context } })` inference | ✅ Parity | Context is statically typed (`MachineConfig<Context>`). The **Tier-2 typed API** models each event as its own `StateEvent` type and keys transitions on it, so guard/action closures receive the **concrete, narrowed event** — no cast, no `assertEvent`. The **`@MachineStates` macro** generates a `StateName` enum from a machine's own declarations, giving compile-checked, autocompleted, rename-safe **targets** (`to: AppState.running`) with zero drift. Achieves XState's typing outcomes through Swift's type identity + macros rather than TS literal inference. |
| `mapState` | ✅ Parity | Nested `StateMap` → `[MapStateEntry]`; `mapStateFirst` for view models |
| `getNextSnapshot` alias | 📋 Planned | `transition()` already provides this |
| **SwiftUI bindings** (`useMachine`, `useSelector`, `useMapState`) | ➕ SwiftXState only | Apple platforms; parallel to `@xstate/react` |
| **Pluggable inspect transports** (`InspectTransport`) | ➕ SwiftXState only | `ClosureInspectTransport`, file/mock transports; URLSession optional |
| `@xstate/react` / Vue / Svelte bindings | ➖ N/A | SwiftUI is the Apple-native binding layer |

### Standards and interchange

| Capability | Status | Notes |
|------------|--------|-------|
| XState machine-definition JSON (export) | ✅ Parity | For Stately graph rendering |
| XState machine-definition JSON (import) | 🔶 Partial | Structural import into the inspector (graph + initial state + click-through stepping); see Inspector & tooling. Behavior (guards/actions/actors) is not reconstructed — it lives in code, not the definition |
| **SCXML** import / export | 📋 Planned | XState itself is SCXML-*inspired* rather than a full SCXML engine; we aim to support practical SCXML interchange for enterprise and telecom workflows |
| W3C SCXML execution semantics (full) | 📋 Planned | Large spec; will be incremental |

### Platform strengths (SwiftXState direction)

| Capability | Status | Notes |
|------------|--------|-------|
| Compiled iOS / macOS / watchOS / tvOS / Linux / Windows apps | ➕ SwiftXState only | No JS runtime required |
| Strict concurrency / `Sendable` machine model | ➕ SwiftXState only | Enabled on core targets |
| C / C++ / Objective-C interop from actions & actors | 📋 Planned | Invoke `fromCallback` / `fromTask` as integration points |
| Offline-first native persistence | ➕ SwiftXState only | SwiftData module; Core Data / file stores possible |

---

## Concurrency: SwiftXState `Actor` vs Swift `actor`

This distinction matters everywhere in the docs and samples — including [SwiftXChess](Examples/SwiftXChess/README.md).

### What is a SwiftXState `Actor`?

`SwiftXState.Actor` is a **reference-type interpreter** (`final class`) that runs a `StateMachine` configuration. It:

- Owns a **mailbox** of events processed on an internal serial `DispatchQueue`
- Maintains a **`MachineSnapshot`** (value, context, tags, children, history)
- Spawns and supervises **child actors** via `invoke` / `spawnChild`
- Schedules **delayed** transitions and raises via a pluggable `Clock`
- Emits **inspection events** compatible with Stately Inspector

```swift
let actor = createActor(machine).start()
actor.send(Event("SUBMIT"))
let snap = actor.snapshot
```

Naming matches XState v5's `createActor` on purpose. A SwiftXState `Actor` is the unit of **behavior** — the running state machine process.

### What is a Swift `actor`?

A Swift `actor` is a **language-level concurrency primitive**: the compiler enforces isolated mutable state, and callers must `await` cross-actor access. It is unrelated to the XState actor model except in name.

```swift
actor SessionStore {
    var sessions: [String: ReplaySession] = [:]
    func save(_ session: ReplaySession) { sessions[session.id] = session }
}
```

### How SwiftXState uses Swift concurrency today

SwiftXState does **not** implement the interpreter as a Swift `actor`. Instead, it uses Swift concurrency **inside** child actor logic:

| XState concept | SwiftXState API | Concurrency |
|----------------|-----------------|-------------|
| `fromPromise` | `fromTask` | `async throws` child runs in a `Task` |
| `fromCallback` | `fromCallback` | `receive`, `sendBack`, `emit`; sync setup + dispose cleanup |
| — | `fromTaskGroup` | `withThrowingTaskGroup` for parallel child work |
| Observable | `fromObservable` | `Subscribable` + async delivery |

The parent `Actor` stays on its serial queue. Async children report back via `sendToParent`, `DoneActorEvent`, `ErrorActorEvent`, and optional `onSnapshot` sync. That keeps transition logic deterministic while still embracing `async`/`await` for I/O.

#### Cancellation, cleanup, and restore policy

Task and task-group children are wrapped in `withTaskCancellationHandler`. Pass an `onCancel` closure to `fromTask` / `fromTaskGroup` to flush SwiftData writes, delete partial batches, or checkpoint before the child tears down:

```swift
fromTask(onCancel: { scope in
    await store.deletePendingBatch(scope.input?.get(String.self))
}) { scope in
    for job in jobs {
        try scope.checkCancellation()  // or: if scope.isCancelled { return }
        await store.write(job)
    }
    return jobs.count
}
```

`TaskActorScope` and `TaskGroupScope` also expose `isCancelled`, `checkCancellation()`, and `withCancellationHandler` for nested cleanup inside long operations.

When hydrating from a persisted snapshot, opaque invokes default to **restart** (fresh child). Set `opaqueRestorePolicy` on `InvokeConfig` or `SpawnRef` to defer auto-spawn until your entry logic reconciles external stores:

| Policy | Behavior on `start(from:)` |
|--------|----------------------------|
| `.restart` (default) | Spawn a new task/callback/taskGroup child |
| `.skipIfActive` | Skip spawn if persisted opaque child was `.active` |
| `.skipIfPresent` | Skip spawn whenever any opaque child snapshot exists |

Pair `.skipIfActive` with entry actions that read SwiftData, clear or resume partial work, then transition or manually re-invoke.

### Anticipated role of Swift `actor` in SwiftXState apps

Swift `actor` is a **complementary tool**, not a replacement for `SwiftXState.Actor`:

1. **App shell and bridges** — A Swift `actor` can own UI-adjacent or cross-boundary state (network clients, BLE, Core Data facades, C++ game engines bridged through Swift) and send `Eventable` values into a SwiftXState `Actor` from `fromCallback` or `fromTask` children.

2. **Persistence and replay services** — `ReplayPersistenceStore`-style services may be modeled as Swift `actor`s to serialize disk access while the machine interpreter handles domain transitions.

3. **Future interpreter isolation** — We may offer an optional Swift-`actor`-backed mailbox implementation behind the same `Actor` API for apps that want compiler-checked isolation instead of `DispatchQueue`. The public XState-shaped API would remain stable.

4. **Not planned: renaming `Actor`** — Consistency with XState and Stately Inspector outweighs avoiding the keyword collision. Documentation and type context (`SwiftXState.Actor`) make the distinction clear.

**Rule of thumb:** use `SwiftXState.Actor` for **orchestration and statecharts**; use Swift `actor` for **resource ownership and async isolation** at the edges; connect them with `invoke` / `fromTask` / `fromCallback`.

---

## Examples

| Example | Location | Demonstrates |
|---------|----------|--------------|
| **SwiftXChess** | [Examples/SwiftXChess](Examples/SwiftXChess/) | Parallel regions, typed `Eventable` events, SwiftUI session bridge, Stately inspect, replay scrubber |
| **InspectorSample** | `Examples/InspectorSample/` | Live Stately Inspector wiring with sample machines (connects via the relay in `Scripts/relay`) |
| **InspectorPasteApp** | `Examples/InspectorPasteApp/` | Paste XState machine-definition JSON → load it into the native inspector and **structurally step** it (click through `on`/`always`/`after`/`onDone`). Source-only — wire into Xcode per its README |
| **Visualizer POC** | `Examples/SX_XS_Visualizer_POC/` | Streams a live machine to the **real Stately.ai inspector** via `Scripts/relay` |

The **Stately relay** is shared tooling in [`Scripts/relay`](Scripts/relay/) — `npm install && npm run relay` bridges any SwiftXState app's inspection stream to a live `stately.ai/registry/inspect/…` session.

Open **SwiftXChess** via `Examples/SwiftXChess/SwiftXChess.xcodeproj` for the most complete app-shaped reference.

---

## Development

```bash
# Run all package tests (Apple platforms)
swift test

# Run core tests only
swift test --filter SwiftXStateTests
```

The core test suite covers guards, invoke/spawn, parallel transitions, history, replay, persistence, inspection, and SwiftXChess integration scenarios.

### Linux smoke test (Ubuntu)

On a Linux host with Swift 6.2+ installed ([swift.org install guide](https://www.swift.org/install/linux/)):

```bash
# Clone or sync the repo, then:
chmod +x Scripts/linux-smoke-test.sh
./Scripts/linux-smoke-test.sh
```

This builds `SwiftXState`, `SwiftXStateInspect`, and the URLSession inspect stub, then runs `SwiftXStateTests` and `SwiftXStateInspectTests`. It skips Apple-only SwiftData test targets. Report failures with `swift --version` and the full script output.

---

## Roadmap (summary)

Near-term priorities to close the remaining XState semantic gaps:

1. **Opaque child checkpoint payloads** — optional persisted job ledger metadata beyond status-only snapshots
2. **SCXML interchange** — import/export for standards-based workflows
3. **`@xstate/graph` algorithms** — ✅ shipped in core: adjacency map, shortest/simple paths, `TestModel` (model-based testing), and `validate` (dead-end / unreachable-state checks)
4. **Machine JSON import** — structural import + click-through simulation shipped (see `InspectorPasteApp`); full round-trip back to `definitionJSON()` still planned
5. **On-device live run of imported machines** *(investigating)* — execute an imported XState machine's real behavior (guards/actions/actors) on iOS/macOS via in-process `JavaScriptCore`, bridging XState's `inspect` callback into `InspectionEvent`, so any JS machine runs live in the native inspector without a Node relay

See the [parity table](#parity-with-xstate) for the full picture.

---

## Related links

- [XState](https://github.com/statelyai/xstate) — the JavaScript reference implementation
- [Stately](https://stately.ai) — visual editor, inspector, and state-machine tooling
- [@statelyai/inspect](https://github.com/statelyai/inspect) — inspector protocol SwiftXState speaks on the wire
- [SCXML (W3C)](https://www.w3.org/TR/scxml/) — historical spec that influenced XState's design

---

## License

SwiftXState is released under the [MIT License](LICENSE).

```
Copyright (c) 2026 Jonathan Gilbert

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

SwiftXState is an independent open-source project inspired by and interoperable with Stately's XState. It is not affiliated with or endorsed by Stately. XState itself is licensed separately by its authors; see the [XState repository](https://github.com/statelyai/xstate) for its terms.