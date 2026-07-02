---
name: swiftxstate-persistence
description: Persist and restore SwiftXState actors — PersistedSnapshot, createActor(machine, snapshot:) hydration, the SwiftXStateSwiftData adapter (ActorPersistenceStore, ReplayPersistenceStore), crash recovery, saving user-action sessions. Use when app state must survive relaunch/crash or sessions must be saved to disk.
---

# Persistence & crash recovery

Two complementary layers: **snapshots** (current state — cheap, restores instantly) and **replay
sessions** (the event history — audit + time-travel; see swiftxstate-undo-redo-replay).

## Core: PersistedSnapshot (no SwiftData required)

`Context: Codable` is the only requirement.

```swift
let persisted = try await actor.getPersistedSnapshot()          // state value + context + children
// … encode/store `persisted` however you like …
let actor = await createActor(machine, snapshot: persisted)    // hydrated AND started:
// restores state configuration + context, RE-SPAWNS children, re-schedules After timers
```

## SwiftData adapter (`import SwiftXStateSwiftData`)

`ActorPersistenceStore` — keyed snapshot records (`ActorSnapshotRecord`: unique key, machineId,
data, updatedAt):

```swift
let store = ActorPersistenceStore(container: modelContainer)
try await store.save(actor, key: "session.main")               // Context: Codable & Sendable
let restored = try store.load(key: "session.main")             // PersistedSnapshot?
let actor = try await store.createActor(machine, key: "session.main")  // load+hydrate one-step
try store.delete(key: "session.main")
```

`ReplayPersistenceStore` — save a `ReplaySession` (or directly an `InspectionRecorder`'s current
session) under a key; `load(key:)` returns the session for replay/verification after relaunch.

## Crash-recovery recipe

1. Autosave on meaningful transitions: subscribe to the actor and `store.save` (debounced) — or
   save in scene-phase `.background`.
2. On launch: `store.load(key:)` → if present, `createActor(machine, snapshot:)`; else fresh
   `createActor(machine)`.
3. Belt & braces: also `ReplayPersistenceStore.save(recorder, key:)` periodically — if a snapshot
   is corrupt/stale, `timeTravel(machine, context: .initial, session: session, toStep: last)`
   rebuilds state from events, and `verifyReplay` checks the recovered state matches history.
4. Version your `Context` (Codable) deliberately — on decode failure fall back to fresh + replay.

## Gotchas

- **SwiftData + parallel tests crash** — serialize suites touching a shared container
  (`.serialized` trait); one `ModelContainer` per test where possible.
- Snapshots capture the *machine's* state, not external world state — an invoked in-flight task is
  restarted (state re-entry), not resumed mid-flight; design invokes idempotent/resumable.
- Keys are your namespace: `"<machineId>.<instance>"` keeps multiple actors of one machine apart.

## Reference files
- `Sources/SwiftXStateSwiftData/` (ActorPersistenceStore, ReplayPersistenceStore, record models)
- Core: `getPersistedSnapshot` / `start(from:)` in `Sources/SwiftXState/Actor/Actor.swift`,
  `createActor(machine, snapshot:)` in `Actor/Global Funcs/createActor.swift`
- Tests: `Tests/SwiftXStateSwiftDataTests/`
