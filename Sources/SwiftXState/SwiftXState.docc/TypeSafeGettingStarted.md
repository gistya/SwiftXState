# Getting Started (Type-Safe)

Build your first machine with compile-time guarantees — typed events and checked state names.

## Overview

This is the **🔵 Advanced** on-ramp. It builds the same toggle as the
<doc:GettingStarted> (Basic) guide, but with two Swift features layered on so the compiler catches
mistakes that the string API would only surface at runtime:

- **Events are types** — you `send` a `Toggle()` value, not an `Event("TOGGLE")` string. Typos
  become compile errors, and (as you'll see in <doc:TypeSafeCoreConcepts>) guards and actions
  receive the *concrete* event with its payload already narrowed.
- **State names are a checked enum** — declare a `StateName` enum with one case per state, so
  transition targets like `State.active` are autocompleted and rename-safe.

It still produces an ordinary ``ResolvedMachine`` — same engine, same `definitionJSON()`, same
inspector behavior as a string-built machine.

## Add the package

Identical to the Basic guide — see <doc:GettingStarted> for the SwiftPM snippet. Then
`import SwiftXState`.

## Your first machine

Two pieces make it type-safe: an event type, and a `StateName` enum for the config's states.

```swift
import SwiftXState

enum ToggleMachine {
    // 1. Each event is a type. `Toggle()` is what you send — compile-checked.
    struct Toggle: StateEvent {}

    // 2. A state enum mirrors the `states:` keys below (`State.inactive`, `State.active`).
    //    `StateName` makes targets checked & autocompleted; `StateID` does the same for snapshot
    //    checks (`inState(.active)`).
    enum State: String, StateName, StateID {
        case inactive
        case active
    }

    static let config = MachineConfig(
        id: "toggle",
        initial: "inactive",
        context: EmptyContext(),
        states: [
            "inactive": StateNodeConfig(on: transitions(
                on(Toggle.self, to: State.active)
            )),
            "active": StateNodeConfig(on: transitions(
                on(Toggle.self, to: State.inactive)
            )),
        ]
    )
}
```

Reading the new pieces:

- `struct Toggle: StateEvent {}` — an event modeled as a type. ``StateEvent`` only requires a
  discriminator string, which defaults to the type name (`"Toggle"`); override `static var
  eventType` for an XState-style dotted name like `"toggle.flip"`.
- `enum State: String, StateName, StateID { case inactive; case active }` — one case per state, raw
  values matching the literal `states:` keys (nested states use a compound case name with a dotted
  raw value, e.g. `case activeFast = "active.fast"`). ``StateName`` brands transition *targets*
  (`to: State.active`); ``StateID`` brands *snapshots* (`inState(.active)`) — a state enum can be
  both.
- `transitions(on(Toggle.self, to: State.active))` — `on(_:to:)` declares a transition keyed by the
  `Toggle` event type, targeting the checked `State.active`; `transitions(_:)` assembles those into
  the dictionary `StateNodeConfig(on:)` expects.

## Run it

Exactly like the Basic path — create an ``Actor``, `start()` it, then `send` typed events. The
actor is a Swift `actor`, so `start` / `send` / `snapshot` are `async`:

```swift
let actor = await createActor(createMachine(ToggleMachine.config)).start()

await actor.snapshot.matches(ToggleMachine.State.inactive)   // true — typed, no string

await actor.send(ToggleMachine.Toggle())                     // a typed event — no string
await actor.snapshot.matches(ToggleMachine.State.active)     // true

await actor.send(ToggleMachine.Toggle())
await actor.snapshot.matches("inactive")                     // string form still works
```

Because `State` conforms to ``StateID``, `matches(_:)` takes the enum directly — the declared enum
is the single source of truth for those names, so reading state stays in sync with the declarations
too.

### Brand the actor for typed snapshots

Pass the state enum to `createActor(_:as:)` and it tags the actor up front, returning a
``TypedActor`` whose snapshots read as typed `inState(_:)` checks:

```swift
let toggle = createActor(createMachine(ToggleMachine.config), as: ToggleMachine.State.self)

let snapshot = await toggle.start()
snapshot.inState(.active)                 // typed membership — no string

await toggle.send(ToggleMachine.Toggle())
await toggle.snapshot.inState(.inactive)
```

If you already hold a plain actor, `actor.typed(as:)` brands it after the fact.

## What this buys you

- **Misspelled events don't compile.** `actor.send(ToggleMachine.Toggle())` is checked; there's no
  `"TOGGEL"` waiting to silently no-op at runtime.
- **Targets can't drift.** Rename a state and the generated `State` enum changes with it — every
  `to: State.…` reference updates or fails to compile.
- **Payloads arrive narrowed.** In <doc:TypeSafeCoreConcepts> you'll see guards and actions receive
  the concrete event type with no `as?` cast.

## Next steps

- <doc:TypeSafeCoreConcepts> — context, narrowed guards/actions, and branching in the typed API.
- <doc:RunningActors> — actor lifecycle, subscriptions, `waitFor`, and child actors (same for both
  paths).
- <doc:AsyncWork> — invoke async work and transition on the result.
- Prefer the string form for a quick sketch? See <doc:GettingStarted>.
