# Core Concepts (Type-Safe)

States, transitions, context, guards, and actions — with typed events and checked state names.

## Overview

This is the **🔵 Advanced** counterpart to <doc:CoreConcepts>. The five ideas are identical; what
changes is that events are Swift types and state targets come from a generated enum, so the
compiler verifies your wiring and your guards/actions receive the **concrete** event — no string
keys, no `as?` casts, no `assertEvent`.

Everything here lowers to ordinary ``TransitionConfig`` / ``ActionRef`` / ``GuardRef``, so the
engine, `definitionJSON()`, and the inspector behave exactly as they would for a string-built
machine.

## Events as types

Model each event as a type conforming to ``StateEvent``. The only requirement is a discriminator
string, which defaults to the type name; override it for XState-style dotted names. Events can
carry payload:

```swift
struct Fetch: StateEvent {}
struct Loaded: StateEvent, Equatable { static let eventType = "LOADED"; let value: String }
struct Failed: StateEvent { static let eventType = "FAILED" }
```

You `send` these as values (`actor.send(Loaded(value: "…"))`), and transitions key on the type.

## States and typed transitions

Attach `@MachineStates` to the config to generate a checked state enum, then target states with
`on(_:to:)`:

```swift
"idle": StateNodeConfig(on: transitions(
    on(Fetch.self, to: State.loading)
)),
```

`on(EventType.self, to: State.case)` is the typed transition: the key is the event type, the target
is a compile-checked `State`. `transitions(_:)` collects entries into the `[String:
TransitionInput]` dictionary `StateNodeConfig(on:)` expects. Multiple entries for the *same* event
become an ordered guarded list (first passing guard wins) — that's how you branch (shown below).

## Context: data that travels with the machine

Context is any `Sendable` type, declared on the config's `context:` — same as the Basic path:

```swift
struct Context: Sendable, Equatable {
    var data: String? = nil
    var retries: Int = 0
}
```

Read it from any snapshot with `actor.snapshot.context`.

## Actions with narrowed events

The typed ``assign(on:_:)`` hands your closure the **concrete** event — no downcast:

```swift
on(Loaded.self, to: State.success, actions: [
    assign { (ctx: inout Context, event: Loaded) in
        ctx.data = event.value        // `event` is a Loaded — `.value` is right there
    }
])
```

Contrast with the Basic path, where you'd write `assign { ctx, args in (args.event as? Loaded)?… }`.
The other ``ActionRef`` actions (`raise`, `sendTo`, `sendParent`, `log`, …) work the same as in
<doc:CoreConcepts>.

## Guards with narrowed events, and branching

A typed `guarded` predicate likewise receives the concrete event. Combine several `on(EventType,…)`
entries for one event to branch — the first whose guard passes is taken:

```swift
"loading": StateNodeConfig(on: transitions(
    on(Loaded.self, to: State.success, actions: [
        assign { (ctx: inout Context, event: Loaded) in ctx.data = event.value }
    ]),
    // Retry up to 3 times on failure …
    on(Failed.self, to: State.loading,
       guard: guarded { (ctx: Context, _: Failed) in ctx.retries < 3 },
       actions: [assign { (ctx: inout Context, _: Failed) in ctx.retries += 1 }]),
    // … then give up.
    on(Failed.self, to: State.failure)
)),
```

Guards must be pure — they only read. A `guarded` predicate that somehow receives the wrong event
type fails closed (returns `false`), which can't happen for a transition keyed on that type but
keeps it total.

## Putting it together

The full fetch machine, type-safe end to end:

```swift
import SwiftXState

enum Fetcher {
    struct Fetch: StateEvent {}
    struct Loaded: StateEvent, Equatable { static let eventType = "LOADED"; let value: String }
    struct Failed: StateEvent { static let eventType = "FAILED" }

    struct Context: Sendable, Equatable {
        var data: String? = nil
        var retries: Int = 0
    }

    @MachineStates("State")
    static let config = MachineConfig(
        id: "fetcher",
        initial: "idle",
        context: Context(),
        states: [
            "idle": StateNodeConfig(on: transitions(
                on(Fetch.self, to: State.loading)
            )),
            "loading": StateNodeConfig(on: transitions(
                on(Loaded.self, to: State.success, actions: [
                    assign { (ctx: inout Context, event: Loaded) in ctx.data = event.value }
                ]),
                on(Failed.self, to: State.loading,
                   guard: guarded { (ctx: Context, _: Failed) in ctx.retries < 3 },
                   actions: [assign { (ctx: inout Context, _: Failed) in ctx.retries += 1 }]),
                on(Failed.self, to: State.failure)
            )),
            "success": StateNodeConfig(type: .final),
            "failure": StateNodeConfig(on: transitions(
                on(Fetch.self, to: State.loading)
            )),
        ]
    )
}

let actor = createActor(createMachine(Fetcher.config)).start()
actor.send(Fetcher.Fetch())
actor.send(Fetcher.Loaded(value: "hello"))
actor.snapshot.matches("success")   // true
```

## Next steps

- <doc:RunningActors> — lifecycle, subscriptions, `waitFor`, and child actors.
- <doc:AsyncWork> — replace the manual `Loaded`/`Failed` events with a real async call via
  `fromTask`, transitioning on its result.
- <doc:NamedImplementations> — register actions/guards/actors by name for reuse and inspection.
