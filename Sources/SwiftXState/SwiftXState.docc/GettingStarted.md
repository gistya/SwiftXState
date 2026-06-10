# Getting Started

Install SwiftXState, build your first machine, and run it.

## Overview

This guide takes you from zero to a running state machine. By the end you'll understand the
three things every SwiftXState program uses: a **config**, a **machine**, and an **actor**.

## Add the package

In Xcode: **File ▸ Add Package Dependencies…** and enter the repository URL. Or, in a
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gistya/SwiftXState.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "SwiftXState", package: "SwiftXState"),
        ]
    ),
]
```

Then `import SwiftXState`.

## Your first machine

A machine is built in two steps: describe it with a ``MachineConfig``, then create it with
``createMachine(_:implementations:)``.

```swift
import SwiftXState

let toggle = createMachine(MachineConfig(
    id: "toggle",
    initial: "inactive",
    context: EmptyContext(),
    states: [
        "inactive": StateNodeConfig(on: ["TOGGLE": .to("active")]),
        "active":   StateNodeConfig(on: ["TOGGLE": .to("inactive")]),
    ]
))
```

Reading that config top to bottom:

- `initial: "inactive"` — the machine starts in the `inactive` state.
- `context: EmptyContext()` — this machine carries no data. (We'll add data in
  <doc:CoreConcepts>.) ``EmptyContext`` is the "no data" placeholder.
- `states:` — a dictionary of state names to ``StateNodeConfig``.
- `on: ["TOGGLE": .to("active")]` — *when in `inactive`, a `TOGGLE` event transitions to
  `active`*. `.to(...)` (on ``TransitionInput``) is the shorthand for a plain target.

The machine itself is **pure and stateless** — it's just the rules. Nothing is "running" yet.

## Run it: create an actor

To actually use a machine, create an ``Actor`` from it and `start()` it:

```swift
let actor = createActor(toggle).start()
```

Now you can **send events** and **read snapshots**:

```swift
actor.snapshot.matches("inactive")   // true — the initial state

actor.send(Event("TOGGLE"))
actor.snapshot.matches("active")     // true

actor.send(Event("TOGGLE"))
actor.snapshot.matches("inactive")   // true
```

- ``Actor/send(_:)`` delivers an event. It's **synchronous** — by the time it returns, the
  transition has fully settled.
- ``Actor/snapshot`` is the current ``MachineSnapshot``: a value you read after each event.
- ``MachineSnapshot/matches(_:)-(String)`` asks "am I in this state?"

Events can be the built-in ``Event`` (a string-typed event, like XState's `{ type: 'TOGGLE' }`)
or your own types — see <doc:CoreConcepts>.

## Observe changes

Polling `snapshot` after every `send` is fine for scripts, but in an app you'll usually want to
react to changes. Subscribe:

```swift
let subscription = actor.subscribe { snapshot in
    print("now in:", snapshot.value)
}

actor.send(Event("TOGGLE"))   // prints: now in: active

// later, when you're done:
subscription.unsubscribe()
```

The handler fires immediately with the current snapshot, then again after every transition.

> Tip: In SwiftUI, prefer the bindings in the **SwiftXStateSwiftUI** module
> (`useMachine` / `useSelector`) instead of subscribing by hand.

## What you just learned

| Piece | Type | Role |
|---|---|---|
| Config | ``MachineConfig`` / ``StateNodeConfig`` | Declares states + transitions |
| Machine | ``StateMachine`` | The pure, reusable definition |
| Actor | ``Actor`` | A running instance you `send` events to |
| Snapshot | ``MachineSnapshot`` | The state + data, read after each event |

## Next steps

- <doc:CoreConcepts> — add data (context), conditional transitions (guards), and side effects
  (actions).
- <doc:RunningActors> — the full actor lifecycle, subscriptions, `waitFor`, and child actors.
- <doc:AsyncWork> — call an API and transition on the result.
