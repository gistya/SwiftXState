# Getting Started (Type-Safe)

Build and run your first machine the **🔵 Advanced** way — typed events and compiler-checked state
targets.

## Overview

This is the same journey as <doc:GettingStarted>, with compile-time guarantees layered on. You'll
build the same toggle machine, but events become Swift **types** and transition targets come from a
checked **state namespace** — so a typo or a renamed state is a build error, not a runtime surprise.

Everything here lowers to the same ``MachineConfig`` / ``ResolvedMachine`` / ``Actor`` as the Basic
path, so `definitionJSON()`, the inspector, and the runtime behave identically.

> Tip: Prefer the string-based path first? See <doc:GettingStarted>. Both build the same machine.

## Model events as types

Instead of `Event("TOGGLE")`, declare each event as a type conforming to ``StateEvent``. The only
requirement is a discriminator string, which defaults to the type name:

```swift
import SwiftXState

struct Toggle: StateEvent {}
```

Events can also carry payload (`struct Loaded: StateEvent { let value: String }`) — see
<doc:TypeSafeCoreConcepts>.

## A checked state namespace

Declare a `String`-backed enum conforming to ``StateName``, one case per state. Its raw values are
the state names your config uses:

```swift
enum State: String, StateName {
    case inactive
    case active
}
```

## Your first typed machine

Build the config exactly as in the Basic path, but target states with `on(_:to:)` — the event is a
**type** and the target is a **compile-checked** `State`:

```swift
let toggle = createMachine(MachineConfig(
    id: "toggle",
    initial: "inactive",
    context: EmptyContext(),
    states: [
        "inactive": StateNodeConfig(on: transitions(on(Toggle.self, to: State.active))),
        "active":   StateNodeConfig(on: transitions(on(Toggle.self, to: State.inactive))),
    ]
))
```

- `on(Toggle.self, to: State.active)` — *when a `Toggle` event arrives, transition to `active`*. The
  target is checked: `State.activ` doesn't compile, and renaming a case updates every reference.
- `transitions(_:)` collects these typed entries into the `[String: TransitionInput]` dictionary
  ``StateNodeConfig`` expects.

## Run it

Create an ``Actor`` and drive it — but now you `send` event **values**, not strings:

```swift
let actor = createActor(toggle).start()

actor.snapshot.matches("inactive")   // true — the initial state

actor.send(Toggle())                 // a typed value — no "TOGGLE" string to mistype
actor.snapshot.matches("active")     // true
```

The payoff grows with the machine: typed events flow into guards and actions as the **concrete**
event (no casts, no `assertEvent`), and every target is checked. See <doc:TypeSafeCoreConcepts>.

> Tip: For a machine that's typed *end to end* — including `send` and `matches` — declare it with the
> result-builder DSL (a `struct` conforming to `StateMachine`), and `createActor` hands back a
> `MachineActor` whose `send(_:)` / `matches(_:)` take your event and state enums directly. See the
> type-safe example in the project README.

## Observe changes

Subscriptions work exactly as in the Basic path — the handler fires immediately, then on every
transition:

```swift
let subscription = actor.subscribe { snapshot in
    print("now in:", snapshot.value)
}
// later: subscription.unsubscribe()
```

## What you just learned

| Piece | Basic | Type-Safe |
|---|---|---|
| Events | `Event("TOGGLE")` | a ``StateEvent`` type (`Toggle`) |
| Targets | `.to("active")` (string) | `on(Toggle.self, to: State.active)` (checked) |
| State names | string literals | a ``StateName`` enum |

## Next steps

- <doc:TypeSafeCoreConcepts> — context, guards, and actions with narrowed events.
- <doc:CoreConcepts> — the same ideas on the string-based path.
- <doc:RunningActors> — the full actor lifecycle, subscriptions, `waitFor`, and child actors.
- <doc:AsyncWork> — call an API and transition on the result.
