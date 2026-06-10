# Core Concepts

States, transitions, context, guards, and actions — the five ideas every machine is built from.

> Tip: This page uses the **🟢 Basic (string-based)** API. For the same concepts with typed events,
> checked state targets, and narrowed guards/actions, see <doc:TypeSafeCoreConcepts>.

## Overview

The <doc:GettingStarted> toggle had states and transitions but no data and no side effects.
Real machines need three more things: **context** (data that travels with the machine),
**guards** (conditions that gate transitions), and **actions** (side effects that run on
transitions). This guide covers all five.

## States and transitions

A machine is a set of named states, exactly one of which is active at a time (within a region).
Each state declares the events it handles in its `on` dictionary:

```swift
"green": StateNodeConfig(on: [
    "TIMER": .to("yellow"),
])
```

A transition's value is a ``TransitionInput``, which has three forms:

- **`.to("yellow")`** — shorthand for a plain target (`.to(...)` on ``TransitionInput``).
- **`.single(TransitionConfig(...))`** — one fully-specified transition with a guard and/or
  actions.
- **`.multiple([...])`** — an ordered list of candidates; the **first** whose guard passes is
  taken. This is how you branch.

States nest, too. A state with `states:` of its own is a **compound** state; declare its
`initial` child. SwiftXState also supports `.parallel` regions, `.final` states, and history —
see ``StateNodeType``.

## Context: data that travels with the machine

Most machines carry data. The data type is the machine's **context** — any `Sendable` type you
choose (usually a struct). Declare it via the config's `context:`:

```swift
struct FetchContext: Sendable, Equatable {
    var retries: Int = 0
    var lastError: String? = nil
}

let machine = createMachine(MachineConfig(
    initial: "idle",
    context: FetchContext(),
    states: [ /* … */ ]
))
```

Read it from any snapshot:

```swift
actor.snapshot.context.retries   // 0
```

> Note: Make context `Equatable` (and `Codable` if you want persistence/replay). Most of the
> library's conveniences — change diffing, snapshots, the inspector — work best when it is.

## Actions: updating context and running side effects

You change context with the `assign` action. The mutating form is the most ergonomic:

```swift
"loading": StateNodeConfig(on: [
    "FAILURE": .single(TransitionConfig(
        target: "failure",
        actions: [
            assign { ctx, args in
                ctx.retries += 1
            }
        ]
    )),
])
```

`assign` closures receive `(inout Context, ActionArgs)`. ``ActionArgs`` carries the current
`context` and the triggering `event`. To read data off a custom event, downcast it:

```swift
assign { ctx, args in
    if let e = args.event as? FailureEvent {
        ctx.lastError = e.message
    }
}
```

Beyond `assign`, the ``ActionRef`` family covers the other XState actions: `raise` (send an
event back into this machine), `sendTo` / `sendParent` (message other actors), `log`, `emit`,
`cancel`, `spawnChild`, and an inline escape hatch:

```swift
actions: [
    .inline { args in print("transitioned on \(args.event.type)") }
]
```

Actions also run on **entry** and **exit** of a state, via `entry:` / `exit:` on
``StateNodeConfig``.

## Guards: conditional transitions

A **guard** is a predicate that must pass for a transition to be taken. Combined with
`.multiple`, guards let one event branch to different targets:

```swift
"green": StateNodeConfig(on: [
    "TIMER": .multiple([
        TransitionConfig(
            target: "green",
            guard: .inline { $0.context.elapsed < 100 }   // stay
        ),
        TransitionConfig(
            target: "yellow",
            guard: .inline { $0.context.elapsed >= 100 }   // advance
        ),
    ]),
])
```

A ``GuardRef`` can be `.inline { args in Bool }`, `.named("…")` (resolved via `setup` — see
<doc:NamedImplementations>), or a composite built with `and` / `or` / `not`. Guards must be
pure: they only read; they never mutate.

## Custom typed events

The string ``Event`` is convenient, but you'll often want events that carry data. Conform a
type to ``Eventable`` — the only requirement is a `type` discriminator string:

```swift
struct FailureEvent: Eventable, Equatable {
    let type = "FAILURE"
    let message: String
}

actor.send(FailureEvent(message: "timeout"))
```

The `type` is what transition keys match on (`on: ["FAILURE": …]`). Inside guards and actions,
downcast `args.event` to the concrete type to read its payload.

## Putting it together

A fetch machine using all five concepts (the async piece is covered in <doc:AsyncWork>):

```swift
struct FetchContext: Sendable, Equatable {
    var data: String? = nil
    var error: String? = nil
    var retries: Int = 0
}

let fetcher = createMachine(MachineConfig(
    id: "fetcher",
    initial: "idle",
    context: FetchContext(),
    states: [
        "idle": StateNodeConfig(on: [
            "FETCH": .to("loading"),
        ]),
        "loading": StateNodeConfig(on: [
            "SUCCESS": .single(TransitionConfig(
                target: "success",
                actions: [assign { ctx, args in
                    ctx.data = (args.event as? LoadedEvent)?.value
                }]
            )),
            "FAILURE": .multiple([
                // Retry up to 3 times, then give up.
                TransitionConfig(
                    target: "loading",
                    guard: .inline { $0.context.retries < 3 },
                    actions: [assign { ctx, _ in ctx.retries += 1 }]
                ),
                TransitionConfig(target: "failure"),
            ]),
        ]),
        "success": StateNodeConfig(type: .final),
        "failure": StateNodeConfig(on: ["FETCH": .to("loading")]),
    ]
))
```

## Next steps

- <doc:RunningActors> — lifecycle, subscriptions, `waitFor`, and child actors.
- <doc:AsyncWork> — replace those manual `SUCCESS`/`FAILURE` events with a real async call.
- <doc:NamedImplementations> — extract inline guards/actions into reusable named ones.
