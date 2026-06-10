# ``SwiftXState``

Model your app's behavior as explicit, visualizable, testable state machines — the XState way, natively in Swift.

## Overview

Welcome to **SwiftXState** — a native Swift port of [XState v5](https://stately.ai/docs). It lets
you describe *what your app does* as a **statechart**: a finite set of named states and the
transitions allowed between them. Instead of juggling a pile of `Bool`s and optionals
(`isLoading`, `error`, `data`, `isRetrying`) and guarding against impossible combinations, you
declare the states once and the machine guarantees you can only ever be in one of them.

> Note: SwiftXState is in **beta**. The APIs described here work today; anything not yet supported
> is called out as a limitation or listed on the roadmap rather than promised.

### What you can build

- **Statecharts, not just enums** — hierarchical (nested) states, parallel regions, history,
  final states with output, guards, entry/exit/transition actions, and typed `context` data.
- **An actor model** — run a machine as an ``Actor`` you `send` events to and read
  ``MachineSnapshot``s from; invoke and spawn child actors; run async work
  (`fromTask` / `fromCallback` / `fromTaskGroup`); message between parents and children.
- **Two authoring styles** — an XState-familiar string API and a type-safe Swift API (below).
- **Visualization & inspection** — every machine exports its structure (`definitionJSON()`), so it
  can be rendered as a live 2D/3D graph and watched in a native inspector as it runs
  (the `SwiftXStateGraph` and `SwiftXStateInspectorUI` modules), or streamed to Stately.
- **Testability** — machines are pure and `Sendable`; the `SwiftXStateGraph` module adds
  `@xstate/graph` path generation and model-based testing.
- **Persistence & replay** — snapshot an actor and restore it, or replay a recorded event log.
- **SwiftUI & SwiftData bindings**, and a cross-platform core (Apple platforms + Linux/Windows).

### Choose your path

There are two ways to author a machine. They share the same engine underneath — pick based on
your goals, and feel free to mix or migrate between them.

**🟢 Basic — string-based API.** States and events are plain strings, mirroring how XState reads in
JavaScript. Less ceremony, no macros — the quickest way to sketch a machine, and the form that
maps 1:1 to XState's JSON for export, interop, and visualization. Ideal for learning and
prototyping.
→ Start at <doc:GettingStarted>, then <doc:CoreConcepts>.

**🔵 Advanced — type-safe Swift API.** Model events as Swift types and let `@MachineStates` generate
a compile-checked enum of state names. Transition targets, event handling, and even guard/action
payloads become compiler-verified — autocomplete, rename-safety, and no stringly-typed bugs. This
is the recommended path for production app logic.
→ Start at <doc:TypeSafeGettingStarted>, then <doc:TypeSafeCoreConcepts>.

Both paths produce an identical runnable machine and identical `definitionJSON()` / inspector
output, so you lose nothing by starting Basic and tightening up later.

### Why statecharts

- **Make impossible states impossible.** If "loading" and "error" are separate states, you can
  never be in both at once — a whole class of bugs can't be represented.
- **See your logic.** The machine's structure is data, so it can be drawn and inspected live.
- **Test logic in isolation.** A machine is pure and decoupled from UI; paths through it can even
  be generated automatically.
- **Familiar across the ecosystem.** Same model, names, and JSON format as XState/Stately.

A **machine** (``StateMachine``) is the pure, reusable definition. You run it by creating an
**actor** (``Actor``) — a live instance you `send` events to and read ``MachineSnapshot``s from.
One machine can back many actors; actors can invoke and spawn child actors, run async work, and
talk to one another.

## Topics

### Get started — Basic (string-based)

- <doc:GettingStarted>
- <doc:CoreConcepts>

### Get started — Advanced (type-safe)

- <doc:TypeSafeGettingStarted>
- <doc:TypeSafeCoreConcepts>

### Going deeper (both paths)

- <doc:RunningActors>
- <doc:AsyncWork>
- <doc:NamedImplementations>

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

### Type-Safe API

- ``StateEvent``
- ``EventTransition``

### Running Machines

- ``Actor``
- ``MachineSnapshot``
- ``StateValue``
- ``SnapshotStatus``
- ``waitFor(_:predicate:options:)``

### Events

- ``Eventable``
- ``Event``

### Async Work & Children

- ``InvokeConfig``
- ``TaskActorLogic``
- ``CallbackActorLogic``
- ``TaskGroupActorLogic``
- ``TaskGroupScope``
- ``DoneActorEvent``

### Named Implementations

- ``MachineImplementations``
- ``SendableValue``
