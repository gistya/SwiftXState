# Migrating from 1.x to 2.0

2.0 unifies the runtime on a single generic engine. In 1.x there was a bespoke
`Actor<Context>` plus a family of hand-written child classes (one per `fromCallback`,
`fromPromise`, `fromObservable`, …). In 2.0 there is **one** actor —
`Actor<L: ActorLogic>` — and every actor kind (machines and all `from*` children) is
just an `ActorLogic` it runs. This mirrors XState v6, where `ActorLogic` is the single
abstraction every actor is built from.

The good news for upgrading: **almost all of your code is source-compatible.** The way
you create and drive actors (`createActor`, `start`, `send`, `snapshot`, `subscribe`,
`on`, persistence, `waitFor`, typed actors) is unchanged. There are only **two**
breaking changes, both about the actor *type*.

---

## TL;DR

| 1.x | 2.0 |
| --- | --- |
| `Actor<MyContext>` | `Actor<MachineLogic<MyContext>>` |
| `let m = actor.machine` (sync) | `let m = await actor.machine` |

If you never write the `Actor<…>` type by name and never read `actor.machine`, **you
have nothing to change** — `createActor(myMachine)` and everything you do with the
result still compiles as-is.

---

## Breaking change 1 — spelling the actor type

`Actor` is now generic over its *logic*, not its *context*. A state-machine actor is
spelled `Actor<MachineLogic<Context>>`.

You only hit this where you write the type explicitly — most often a stored property in
a view-model / session object:

```diff
 @MainActor @Observable
 final class LightSession {
-    let actor: Actor<LightContext>
+    let actor: Actor<MachineLogic<LightContext>>

     init() {
         actor = createActor(trafficLight)   // ← unchanged; inferred type is the new one
     }
 }
```

`createActor(_:)` (and all its overloads), the `Actor(_ machine:)` initializer,
`useMachine`, `OptimisticMachineDriver`, the SwiftData store, and `MachineGraphView`
all now produce / accept `Actor<MachineLogic<Context>>`. Call sites that rely on type
inference need no change; only explicit annotations do.

### Prefer the old spelling? Add a typealias

The library no longer ships a `Context`-parameterized alias (the canonical type is the
logic-parameterized one). If you want to minimize churn, define your own:

```swift
typealias MachineActor<Context: Sendable> = Actor<MachineLogic<Context>>

// then your 1.x annotations work unchanged:
let actor: MachineActor<LightContext>
```

## Breaking change 2 — `actor.machine` is now `async`

In 1.x `machine` was a synchronous `nonisolated let`. In 2.0 it's an actor-isolated
async property, so reads need `await`:

```diff
-let definition = actor.machine
+let definition = await actor.machine
```

This is rarely an issue in practice — you almost always already hold the
`StateMachine` you passed to `createActor`, so read it from there instead of round-
tripping through the actor.

---

## What did *not* change

All of the day-to-day surface is identical — no edits needed:

```swift
let actor = createActor(toggle)           // create
await actor.start()                       // start (start(input:) / start(context:) too)
await actor.send(Event("TOGGLE"))         // send
await actor.snapshot.matches("on")        // read state
await actor.subscribe { snapshot in … }   // observe
await actor.on("notify") { emitted in … } // emitted events
await actor.stop()                        // stop

// persistence
let data = try await actor.getPersistedSnapshot()
await createActor(toggle).start(from: persisted)

// typed actors
let typed = createActor(player, as: Mode.self)
let branded = createActor(player).typed(as: Mode.self)

// waiting
let settled = try await actor.waitFor { $0.matches("ready") }
```

`createActor`, `createActor(_:as:)`, `TypedActor`, `MachineSnapshot`, `ActorOptions`,
`createMachine`, `useMachine`, `useSelector`, SwiftData `save`/`restore`, the inspector,
and the SwiftUI/Graph integrations keep the same public signatures and behavior.

> **Note** Actors stayed Swift `actor`s (as in 1.1.0), so `send` / `snapshot` / `start`
> were already `async`. If you're coming from an *older* 1.x that predates the actor
> conversion, also expect those to require `await`.

---

## What's new (additive — nothing to migrate)

Because the engine is now parameterized by `ActorLogic`, that protocol — and the
vocabulary around it — is public. You can write your **own** actor logic and run it on
the same engine, the way the built-in `from*` kinds do:

```swift
struct CounterLogic: ActorLogic {
    struct State: Sendable, Equatable { var count = 0 }
    func initialState(input: SendableValue?) -> State { State() }
    func step(_ s: State, on event: any Eventable) -> State {
        event.type == "INC" ? State(count: s.count + 1) : s
    }
    func status(of s: State) -> SnapshotStatus { .active }
}

let counter = Actor(CounterLogic())
await counter.start()
await counter.send(Event("INC"))
```

The newly public types: `Actor<L>`, `ActorLogic`, `MachineLogic`, `MachineActorLogic`,
`ActorScope`, `MachineHost`, and `PersistableLogic`. `MachineLogic<Context>` is the
built-in logic behind every state-machine actor — which is why the actor type is now
`Actor<MachineLogic<Context>>`.

---

## Checklist

- [ ] Replace explicit `Actor<Context>` annotations with `Actor<MachineLogic<Context>>`
      (or define `typealias MachineActor<Context> = Actor<MachineLogic<Context>>`).
- [ ] Add `await` to any `actor.machine` reads (or read your own `StateMachine` value).
- [ ] Rebuild — that's it. No changes to `createActor`, `send`, `snapshot`, `start`,
      persistence, typed actors, `waitFor`, or any framework integration.
