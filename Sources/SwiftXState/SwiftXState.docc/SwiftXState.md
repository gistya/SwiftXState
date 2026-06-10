# ``SwiftXState``

Model your app's behavior as explicit, visualizable, testable state machines — the XState way, natively in Swift.

## Overview

SwiftXState is a native Swift port of [XState v5](https://stately.ai/docs). It lets you
describe *what your app does* as a **statechart**: a finite set of named states and the
transitions allowed between them. Instead of juggling a pile of `Bool`s and optionals
(`isLoading`, `error`, `data`, `isRetrying`) and guarding against impossible combinations,
you declare the states once and the machine guarantees you can only ever be in one of them.

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

let actor = createActor(toggle).start()
actor.send(Event("TOGGLE"))
actor.snapshot.matches("active")   // true
```

A **machine** (``StateMachine``) is the pure, reusable definition. You run it by creating an
**actor** (``Actor``) — a live instance you `send` events to and read ``MachineSnapshot``s from.
One machine can back many actors; actors can invoke and spawn child actors, run async work, and
talk to one another.

### Why statecharts

- **Make impossible states impossible.** If "loading" and "error" are separate states, you can
  never be in both at once. A whole class of bugs simply can't be represented.
- **See your logic.** Every machine exports its structure as JSON, so it can be rendered as a
  live graph and inspected as it runs (see the `SwiftXStateGraph` and `SwiftXStateInspectorUI`
  modules).
- **Test logic in isolation.** Machines are pure and `Sendable` — decoupled from any UI. You can
  drive them directly in tests, and `SwiftXStateGraph` can auto-generate paths that walk every
  transition.
- **Familiar across the ecosystem.** Same model, names, and JSON format as XState/Stately, so
  TypeScript developers feel at home and Stately's tooling can connect to your running app.

### New here? Start with the guides

If you're new to SwiftXState (or to statecharts in general), read these in order:

1. <doc:GettingStarted> — install, build your first machine, run it.
2. <doc:CoreConcepts> — states, transitions, context, guards, and actions.
3. <doc:RunningActors> — the actor lifecycle, reading state, subscribing, child actors.
4. <doc:AsyncWork> — async effects with `fromTask`, `fromCallback`, and `fromTaskGroup`.
5. <doc:NamedImplementations> — `setup` and reusable named actions/guards/delays/actors.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:CoreConcepts>
- <doc:RunningActors>

### Building Machines

- ``createMachine(_:implementations:)``
- ``MachineConfig``
- ``StateNodeConfig``
- ``StateNodeType``
- ``EmptyContext``

### Transitions, Guards & Actions

- ``TransitionInput``
- ``TransitionConfig``
- ``GuardRef``
- ``ActionRef``
- ``ActionArgs``

### Running Machines

- <doc:RunningActors>
- ``Actor``
- ``MachineSnapshot``
- ``StateValue``
- ``SnapshotStatus``
- ``waitFor(_:predicate:options:)``

### Events

- ``Eventable``
- ``Event``

### Async Work & Children

- <doc:AsyncWork>
- ``InvokeConfig``
- ``TaskActorLogic``
- ``CallbackActorLogic``
- ``TaskGroupActorLogic``
- ``TaskGroupScope``
- ``DoneActorEvent``

### Named Implementations

- <doc:NamedImplementations>
- ``MachineImplementations``
- ``SendableValue``
