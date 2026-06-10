# Running Actors

The actor lifecycle, reading state, observing changes, and coordinating child actors.

## Overview

A ``StateMachine`` is just the rules. An ``Actor`` is a *running instance* of those rules — the
thing you actually interact with. This guide covers the actor's lifecycle and the ways you read
from and react to it.

> Note: This page applies to **both** the Basic (<doc:GettingStarted>) and Type-Safe
> (<doc:TypeSafeGettingStarted>) paths. Examples use string events/state names; the inline
> *"Type-safe equivalent"* notes show the typed form where the two differ.

## Creating and starting

`createActor` builds an actor from a machine; `start()` boots it into its initial state. Until
you call `start()`, reading `snapshot` will trap — always start first.

```swift
let actor = createActor(machine).start()
```

You can seed an actor at creation:

```swift
// Provide input that the machine turns into initial context
let actor = createActor(machine, input: SendableValue(userId)).start()

// Or override the starting context outright
let actor = createActor(machine).start(context: FetchContext(retries: 2))
```

Stop an actor when you're done; this exits its states (running their `exit` actions) and tears
down any children and timers:

```swift
actor.stop()
```

## Reading state

After every event, the actor exposes a fresh ``MachineSnapshot`` via ``Actor/snapshot``:

```swift
let snap = actor.snapshot

snap.matches("loading")        // in this state?
snap.context.retries           // read context
snap.value                     // the StateValue (e.g. .atomic("loading"))
snap.status                    // .active / .done / .error / .stopped
snap.hasTag("busy")            // state tags
snap.can(Event("FETCH"))       // would this event cause a transition?
snap.output                    // set when a final state is reached (status == .done)
```

``MachineSnapshot/matches(_:)-(String)`` accepts dotted paths for nested states, e.g.
`snap.matches("checkout.payment")`.

> Note: **Type-safe equivalent.** With `@MachineStates`, read state from the generated enum so the
> check can't drift from your declarations: `snap.matches(State.loading.rawValue)`.

## Sending events

``Actor/send(_:)`` is **synchronous** and **run-to-completion**: when it returns, the transition
(and any events raised during it) have fully settled. Send the built-in ``Event`` or your own
``Eventable`` types:

```swift
actor.send(Event("FETCH"))
actor.send(FailureEvent(message: "timeout"))
```

> Note: **Type-safe equivalent.** On the typed path, events are ``StateEvent`` types you send as
> values — `actor.send(Fetch())` — so a misspelled event is a compile error, not a silent no-op.
> See <doc:TypeSafeCoreConcepts>.

## Observing changes

Subscribe to be notified on every transition. The handler fires once immediately with the
current snapshot, then after each change:

```swift
let sub = actor.subscribe { snapshot in
    updateUI(for: snapshot)
}
// …
sub.unsubscribe()
```

> Tip: For SwiftUI, reach for the **SwiftXStateSwiftUI** module instead of subscribing manually —
> it bridges an actor to `@Observable`/property wrappers for you.

## Awaiting a state (async)

In async code — including tests — use ``waitFor(_:predicate:options:)`` to suspend until the
machine reaches a condition. It checks the current snapshot first, then waits, and throws on
timeout or if the actor stops:

```swift
actor.send(Event("FETCH"))
let done = try await waitFor(actor) { $0.matches("success") }
print(done.context.data as Any)
```

## Child actors

Actors compose. A parent can run other actors as children, two ways:

- **`invoke`** — a child tied to a *state*. It starts when the state is entered and is stopped
  automatically when the state is exited. Declared on ``StateNodeConfig`` via ``InvokeConfig``.
- **`spawnChild`** — a child started imperatively from an *action*, living until you stop it (or
  the parent stops). One of the ``ActionRef`` cases.

Children can be async work (`fromTask`, `fromCallback`, `fromTaskGroup`) or other state machines.
Invoking a child machine and reacting to its result:

```swift
"loading": StateNodeConfig(
    invoke: [
        InvokeConfig(
            id: "loader",
            src: fromTask { _ in try await api.load() },
            onDone: .to("success"),
            onError: .to("failure")
        )
    ]
)
```

Parents and children message each other with the `sendTo` / `sendParent` / `forwardTo` actions,
and a snapshot exposes child snapshots via ``MachineSnapshot/children``. See <doc:AsyncWork> for
the async-logic side, and the **SwiftXStateInspectorUI** module to watch a whole actor tree live.

## Next steps

- <doc:AsyncWork> — `fromTask`, `fromCallback`, `fromTaskGroup`, and reacting to their results.
- <doc:NamedImplementations> — name your actors so they're reusable and inspectable.
