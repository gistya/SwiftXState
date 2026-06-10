# Getting Started (Type-Safe)

Build your first machine with compile-time guarantees — typed events and checked state names.

## Overview

This is the **🔵 Advanced** on-ramp. It builds the same toggle as the
<doc:GettingStarted> (Basic) guide, but with two Swift features layered on so the compiler catches
mistakes that the string API would only surface at runtime:

- **Events are types** — you `send` a `Toggle()` value, not an `Event("TOGGLE")` string. Typos
  become compile errors, and (as you'll see in <doc:TypeSafeCoreConcepts>) guards and actions
  receive the *concrete* event with its payload already narrowed.
- **State names are generated** — `@MachineStates` reads your `states:` and emits a compile-checked
  enum, so transition targets like `State.active` are autocompleted and rename-safe. They can never
  drift from the states you actually declared.

It still produces an ordinary ``StateMachine`` — same engine, same `definitionJSON()`, same
inspector behavior as a string-built machine.

## Add the package

Identical to the Basic guide — see <doc:GettingStarted> for the SwiftPM snippet. Then
`import SwiftXState`.

## Your first machine

Two pieces make it type-safe: an event type, and `@MachineStates` on the config.

```swift
import SwiftXState

enum ToggleMachine {
    // 1. Each event is a type. `Toggle()` is what you send — compile-checked.
    struct Toggle: StateEvent {}

    // 2. @MachineStates reads the `states:` keys below and generates a `State` enum
    //    (`State.inactive`, `State.active`), so targets are checked & autocompleted.
    @MachineStates("State")
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
- `@MachineStates("State")` — a macro **attached to the config** that generates `enum State: String,
  StateName { case inactive; case active }` from the literal `states:` keys. Because it must
  introduce a peer type, it has to live **inside a type** (here, the `ToggleMachine` enum) — it
  can't be applied to a file-scope `let`.
- `transitions(on(Toggle.self, to: State.active))` — `on(_:to:)` declares a transition keyed by the
  `Toggle` event type, targeting the checked `State.active`; `transitions(_:)` assembles those into
  the dictionary `StateNodeConfig(on:)` expects.

## Run it

Exactly like the Basic path — create an ``Actor``, `start()` it, then `send` typed events:

```swift
let actor = createActor(createMachine(ToggleMachine.config)).start()

actor.snapshot.matches("inactive")          // true

actor.send(ToggleMachine.Toggle())          // a typed event — no string
actor.snapshot.matches(ToggleMachine.State.active.rawValue)   // true

actor.send(ToggleMachine.Toggle())
actor.snapshot.matches("inactive")          // true
```

`State.active.rawValue` is just `"inactive"`/`"active"` — the generated enum is the single source of
truth for those names, so reading state stays in sync with the declarations too.

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
