---
name: swiftxstate-concurrency
description: SwiftXState concurrency architecture — main-actor UI stores coupled to background machine actors, Sendable contexts, subscription hops, weak-box patterns, session objects. Use when deciding where state lives (main vs background), fixing Sendable/isolation errors around actors and stores, or architecting app-state decoupling.
---

# SwiftXState concurrency model

**The core split:** business logic and app state run in **background Swift actors**
(`Actor<MachineLogic<Context>>` — a real `actor`); the UI observes through **@MainActor stores**
(`MachineStore`/`MainStore`) that receive snapshot hops. UI never blocks on logic; logic never
touches the view tree.

```
SwiftUI View ──send(event)──▶ MachineStore (@MainActor, @Observable)
                                   │ Task { await machineActor.send(...) }
                                   ▼
                             MachineActor<M> ──▶ Actor<MachineLogic<Ctx>>   (background actor)
                                   ▲                    │ spawns/sends to child actors
                                   └──subscribe hop─────┘ (snapshot → MainActor.run → store updates)
```

## Rules

- **Context must be a `Sendable` value type** (struct/enum). It crosses the actor boundary on every
  snapshot. No classes, no closures capturing UI.
- **Handlers (`.action`, `.when`, `.onEntry`) are `@Sendable`** and run inside the actor — they may
  not touch main-actor state. Get data in via context/events; get effects out via `enq`
  (raise/sendTo/emit/spawn) or `emit` → an `on(_:)` listener that hops to main.
- **Subscriptions across @Sendable boundaries:** don't capture `self` of a @MainActor class in the
  subscribe closure directly — use the weak-box pattern (`WeakStoreBox`, an `@unchecked Sendable`
  weak holder) as `MachineStore` does internally (`Sources/SwiftXStateSwiftUI/MainStore.swift`).
- **`ActorOptions.useMainExecutor`** exists for the rare machine that must run on main (e.g. it
  drives AVFoundation objects that require main). Default off — prefer background + emit.
- **Session objects** (the app-level pattern): a `@MainActor @Observable final class` owning a
  `MachineActor<M>`, mirroring `snapshot` after each send. See
  `Examples/SwiftXChess/SwiftXChess/DistributedChessSession.swift` — typed sends, computed `.actor`
  escape hatch for inspection, `private(set) var snapshot` republished to views.

```swift
@MainActor @Observable final class Session {
    let machineActor: MachineActor<GameMachine>
    private(set) var snapshot: MachineSnapshot<GameContext>
    var context: GameContext { snapshot.context }

    func tap(_ sq: Square) async {
        await machineActor.send(.tap(sq))            // typed; runs on the background actor
        snapshot = await machineActor.actor.snapshot // hop the result back
    }
}
```

## Multi-actor concurrency

Each spawned child is its own Swift actor — 96+ concurrent actors is a supported, tested pattern
(SwiftXChess board). Parent→child messaging is `enq.sendTo` (ordered per macrostep); child→parent
delivery is serialized by the engine (`ParentDeliveryChain`) so done/error events can't race ahead
of earlier sends. Don't add your own locks around machine state — the actor *is* the lock.

## Known crashers / gotchas

- **Release-build swiftc crash: `isolated deinit` on a generic class below a macOS 15.4 deployment
  floor.** If a Release build of a consumer app crashes the compiler, check deployment target.
- Long synchronous work inside an `.action` stalls that actor's mailbox — push it to a task child
  (see swiftxstate-tasks skill) and come back via `onDone`.
- `Task { }` inside a handler escapes RTC ordering — fine for fire-and-forget side channels
  (logging, analytics); wrong for state effects (use `enq`).

## Reference files
- `Sources/SwiftXState/Actor/Actor.swift` (the engine actor), `ActorOptions.swift`
- `Sources/SwiftXState/DSL/MachineActor.swift` (typed facade; `subscribe` hop)
- `Sources/SwiftXStateSwiftUI/MainStore.swift` (weak-box, main-actor mirroring)
