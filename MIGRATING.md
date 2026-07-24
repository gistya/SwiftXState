# Migrating from 1.x to 2.0

2.0 unifies the runtime on a single generic engine. In 1.x there was a bespoke
`Actor<Context>` plus a family of hand-written child classes (one per `fromCallback`,
`fromPromise`, `fromObservable`, …). In 2.0 there is **one** actor —
`Actor<L: ActorLogic>` — and every actor kind (machines and all `from*` children) is
just an `ActorLogic` it runs. This mirrors XState v6, where `ActorLogic` is the single
abstraction every actor is built from.

The good news for upgrading: **almost all of your code is source-compatible.** The way
you create and drive actors (`createActor`, `start`, `send`, `snapshot`, `subscribe`,
`on`, persistence, `waitFor`) is unchanged. The **two** breaking changes you're most
likely to hit are both about the actor *type* (plus one note on typed actors at the end).

---

## TL;DR

| 1.x | 2.0 |
| --- | --- |
| `Actor<MyContext>` | `Actor<MachineLogic<MyContext>>` |
| `let m = actor.machine` (sync) | `let m = await actor.machine` |
| `struct Ctx: Codable` (persisted) | `import SwiftXStateCodable` + `struct Ctx: Codable, ContextPersistable` |

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

## Breaking change 3 — `Codable` support moved to `SwiftXStateCodable`

So the core can target **Embedded Swift** (where `Codable` is unavailable — it needs
existentials and type metadata), the core module no longer contains any JSON *engine* or
`Codable`-constrained API. `JSONValue` is now written and parsed by a hand-rolled,
dependency-free codec, so machine export/import works everywhere; everything needing
`Codable` moved to a new **`SwiftXStateCodable`** library. This mirrors how
`FridayTheThirteenth` (the engine) is split from `FridayTheCodable` (the adapters).

Core gained a persistence seam, `ContextPersistable`, which asks a context to project itself
to `JSONValue` instead of reflecting over it. **You don't implement it by hand** — importing
`SwiftXStateCodable` supplies both requirements for any `Codable` type:

```diff
+import SwiftXStateCodable

-struct MyContext: Codable, Sendable, Equatable {}
+struct MyContext: Codable, Sendable, Equatable, ContextPersistable {}   // ← no body needed
```

Everything else about persistence is unchanged: `getPersistedSnapshot(from:children:)` and
`restoreSnapshot(machine:persisted:context:)` keep their original `Codable`-constrained
signatures (they live in the adapter now), and the **on-disk format is byte-identical** — old
snapshots still load, so there's no data migration.

> **Watch out:** a *child* machine's context needs the conformance too. Without it the child
> quietly takes the non-persistable spawn path and its state won't appear in
> `persisted.children`. If a child stops round-tripping, this is why.

The property-map form of `assign([...])` runs through this seam as well. It used to silently
drop the assignment when the context couldn't be rebuilt; it now trips an `assertionFailure`
in debug builds naming the type that needs the conformance.

### Which modules need the import

| You use | Needs `import SwiftXStateCodable` |
| --- | --- |
| `getPersistedSnapshot` / `restoreSnapshot` / `actor.start(from:)` | ✅ |
| `PersistedSnapshot.encodeJSON()` / `.decodeJSON(_:)` | ✅ |
| `ReplaySession.encodeJSON()` / `.decodeJSON(_:)` | ✅ |
| `JSONValue.fromEncodable(_:)` / `.decode(_:)`, `replayDecodeEvent` | ✅ |
| A `Codable` type conforming to `GuardParamValues` | ✅ |
| `SwiftXStateSwiftData` persistence | ✅ |
| `assign([...])` property-map form | ✅ |
| Machines, actors, atoms, `definitionJSON()`, the inspector | ❌ core only |

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

// waiting
let settled = try await actor.waitFor { $0.matches("ready") }
```

`createActor`, `MachineSnapshot`, `ActorOptions`, `createMachine`, `useMachine`,
`useSelector`, SwiftData `save`/`restore`, the inspector, and the SwiftUI/Graph
integrations keep the same public signatures and behavior.

> **Typed actors changed.** The 1.x `createActor(_:as:)` / `TypedActor` state-branding was
> removed. The type-safe authoring path in 2.0 is the `StateMachine` result-builder DSL:
> declare your machine as a `StateMachine` (with `StateIdentifying` / `EventIdentifying`
> enums) and `createActor` hands back a fully-typed `MachineActor` whose `send` / `matches` /
> `start` are compile-checked. See the type-safe guide in the README / DocC.

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
`ActorScope`, `MachineHosting`, and `PersistableLogic`. `MachineLogic<Context>` is the
built-in logic behind every state-machine actor — which is why the actor type is now
`Actor<MachineLogic<Context>>`.

---

## Breaking changes since 2.0 (alpha)

Small, and all in service of Embedded Swift compatibility. Nothing here changes machine semantics.

### `TimeoutHandle` is an opaque token

Sharpest edge, because custom clocks are a documented extension point (WASI/JS hosts are told to
inject one). It used to box `any Sendable`, and each clock recovered its payload with a conditional
cast. It now carries a `UInt64`:

```swift
public struct TimeoutHandle: Sendable, Hashable {
    public let id: UInt64
}
```

A custom `Clock` keeps its own id-to-timer table instead of stuffing the timer into the handle. Both
the existential and the cast are prohibited on Embedded, and the token is simpler regardless.

### `ActorOptions.clock` is a `ClockHandle`

`Clock` is still the protocol you conform to; `ClockHandle` is how the engine *stores* one — a
protocol existential needs a runtime witness table, closures do not. `ActorOptions(clock: MyClock())`
compiles unchanged, because the initializer is generic and erases for you. Only code *reading*
`options.clock` sees the new type.

### `ActorAsyncCancellation.checkCancellation()` uses typed throws

```swift
public static func checkCancellation() throws(CancellationError)
```

An untyped `throws` boxes into `any Error`, which Embedded does not permit. `try` sites are
unaffected; a `catch` that matched other error types may now warn as unreachable.

### `SendableValue` equality is type-safe

Previously it compared `String(describing:)` of the two boxed values. It now compares by concrete
type, so **two distinct types that rendered identically used to be equal and no longer are**. The old
behaviour relied on reflection and was arguably always a bug, but it is a behaviour change.

### Additive, nothing to do

- `Eventable.replayPayload` and `ChildActorRepresentable.makePersistedChildSnapshot()` are new
  requirements with defaults — existing conformers are unaffected. They replace runtime casts to
  `any ReplayPayloadRepresentable` / `any PersistedChildSnapshotProviding`, which Embedded prohibits.
- Inspection events are now delivered in **causal order**. They previously raced: one unstructured
  task per event meant N events could reach the transport in any of N! orders, which corrupted the
  Stately sequence view and Diff Mode's keyframe counter.

## Checklist

- [ ] Replace explicit `Actor<Context>` annotations with `Actor<MachineLogic<Context>>`
      (or define `typealias MachineActor<Context> = Actor<MachineLogic<Context>>`).
- [ ] Add `await` to any `actor.machine` reads (or read your own `StateMachine` value).
- [ ] If you persist, replay, use `assign([...])`, or have `Codable` guard/action params:
      add `import SwiftXStateCodable` and add `ContextPersistable` to those context types
      (no body required) — **including any child machine's context**.
- [ ] Rebuild — that's it. No changes to `createActor`, `send`, `snapshot`, `start`,
      the persisted data format, typed actors, `waitFor`, or any framework integration.

---

## What's new — Diff Mode (optional)

Inspection can now publish only what *changed* in an actor's context instead of the whole
thing, which matters when you're streaming to a remote API and don't want to resend
unchanged fields:

```swift
InspectClientConfiguration(
    wireFormat: .envelope,
    contextPublishing: .diff(keyframeEvery: 50)   // or .selected([...]), .none
)
```

`.full` is the default, so **existing setups are unaffected**. In `.diff` mode a snapshot
carries `contextDelta` (a `ContextDelta` — `unchanged` / `replace` / `merge` / `removed`)
instead of a full `context`, with a full keyframe on an actor's first snapshot, every
`keyframeEvery` snapshots, and on every reconnect. Apply a delta with
`ContextDelta.fromJSON(_:)?.applied(to:)`.

> Choosing any mode other than `.full` applies to **every** wire format, including
> `.stately` — the delta rides in an extra `contextDelta` key that stock
> `@statelyai/inspect` ignores, so use the reduced modes with your own inspector.
