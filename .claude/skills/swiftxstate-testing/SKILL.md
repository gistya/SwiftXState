---
name: swiftxstate-testing
description: Test SwiftXState machines without flakiness — waitForSnapshot/signal patterns instead of Task.sleep, typed MachineActor assertions (matches(path:)), recorder-based side channels, structural mirror tests, replay verification, injected clocks for After. Use when writing or fixing tests for machines, actors, or machine-driven apps.
---

# Testing machines (non-flaky patterns)

House rule: **no `Task.sleep` for correctness** — wait on conditions, not durations.

## The basic shape (Swift Testing)

```swift
@Test func forfeitsOnlyTheMatchingSide() async {
    let m = createActor(ChessLike())            // MachineActor — typed throughout
    await m.start()
    await m.send(.tap(1))
    #expect(await m.matches(path: "castling.wk.forfeited"))
    #expect(await m.matches(path: "castling.wq.available"))   // parallel isolation
    #expect(await m.context.selected == nil)
}
```

`matches(path:)` reaches nested/parallel substates (`"game.active.turn.idle"`); `matches(_ id:)`
for atomic ids; `configuration` for whole-tree assertions; `context` for data.

## Waiting on async effects

- **Engine-tracked conditions**: `await actor.waitForSnapshot { $0.children["bulb"] != nil }` —
  blocks until a snapshot satisfies the predicate (spawns, invoke completion, context changes).
- **Side channels for child behavior**: to prove a child received a payload, inject a tiny
  `actor Recorder { var received: [T] }` into the child machine and spin-yield:
  `while await recorder.count < 2, spins < 10_000 { await Task.yield(); spins += 1 }`.
  (Do NOT assert on `snapshot.children[id]?.value` — it's unreliable even with syncSnapshot.)
- **Timers**: inject a test clock via `ActorOptions(clock:)` and advance it — never wall-clock an
  `After`.

## Determinism checks

`verifyReplay(machine, context: .initial(), session: recordedSession)` re-runs a recorded session
and diffs every step — the strongest regression net for machine logic (catches nondeterministic
handlers: Date(), random, ambient reads). Record with `InspectionRecorder` in the test itself.

## Structural mirror tests (for machines living in unbuildable targets)

When a machine lives in an app target the package tests can't compile (e.g. an .xcodeproj example),
write an in-package **mirror**: a small `StateMachine` reproducing the exact *construct set*
(hierarchy shape, guard styles, spawn/sendTo patterns) with stub handlers, and assert the behavior
there. See `Tests/SwiftXStateTests/DSLChessStructureTests.swift`,
`DSLGameWatcherStructureTests.swift`, `DSLBoardInspectorStructureTests.swift`. Caveat learned the
hard way: mirrors verify DSL constructs, not the app files themselves — the app's own call sites
still need a compile (three staleness classes: renamed symbols, changed type-shapes, and LOST
CONFORMANCES like Eventable — only the compiler catches the last).

## SwiftData-backed tests

Suites touching a shared `ModelContainer` must be `.serialized` (parallel access crashes);
prefer a fresh in-memory container per test.

## Running

```bash
swift test --package-path /path/to/SwiftXState --filter DSLSpawnTests
```

Note: one legacy parallel-run inspection test is occasionally flaky under full-suite load — rerun
before assuming your change broke it.

## Reference files
- `Tests/SwiftXStateTests/DSL*.swift` — a focused suite per DSL feature (the best usage examples in the repo)
- `Tests/SwiftXStateSwiftUITests/` — store/bind/view patterns incl. name-coexistence proof
- Async helpers: `waitForSnapshot` / signal utilities in the test support sources
