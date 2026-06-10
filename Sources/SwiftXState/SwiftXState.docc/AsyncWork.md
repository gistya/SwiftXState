# Asynchronous Work

Call APIs, run listeners, and fan out concurrent work — then transition on the result.

## Overview

Real machines talk to the outside world: they fetch data, listen to streams, run timers. In
SwiftXState that work is modeled as **actor logic** you `invoke` from a state. When the state is
entered the work starts; when it's exited the work is cancelled. You react to the outcome with
`onDone` / `onError` transitions.

> Note: This page applies to **both** authoring paths (<doc:GettingStarted> /
> <doc:TypeSafeGettingStarted>). The actor-logic API is identical; only how you write the
> surrounding transitions differs.

There are three building blocks, each mirroring an XState `fromX`:

| Helper | XState equivalent | Use for |
|---|---|---|
| `fromTask` | `fromPromise` | A single `async` call that returns one value |
| `fromCallback` | `fromCallback` | A long-running listener that sends events over time |
| `fromTaskGroup` | (Swift addition) | Fanning out N concurrent operations |

## `fromTask` — one async call

The workhorse. Wrap any `async throws` call; its return value becomes the `onDone` event's
output, and a thrown error routes to `onError`:

```swift
"loading": StateNodeConfig(
    invoke: [
        InvokeConfig(
            id: "load",
            src: fromTask { scope in
                try await api.fetchProfile()      // -> Profile
            },
            onDone: .single(TransitionConfig(
                target: "ready",
                actions: [assign { ctx, args in
                    if let e = args.event as? DoneActorEvent {
                        ctx.profile = e.output?.get(Profile.self)
                    }
                }]
            )),
            onError: .to("failed")
        )
    ]
)
```

The result arrives as a ``DoneActorEvent``; pull the typed value out with
`event.output?.get(Type.self)`. The output type must be `Sendable & Equatable`.

> Note: **On the type-safe path**, framework events like ``DoneActorEvent`` are ``Eventable`` but
> *not* ``StateEvent``, so the narrowed `assign`/`guarded` helpers from <doc:TypeSafeCoreConcepts>
> don't apply to them — handle `onDone`/`onError` with the standard form shown above
> (`args.event as? DoneActorEvent`). The typed helpers are for *your* `StateEvent` types.

Pass data *into* the task with `input:` (resolved from context/event at invoke time) and read it
from the task scope. Cancellation is automatic on state exit; supply an `onCancel:` closure for
cleanup.

## `fromCallback` — a long-running listener

When the source produces *many* events over time (a socket, a notification observer, a timer),
use `fromCallback`. You're handed a scope to `sendBack` events into the parent, and you return a
cleanup closure that runs on cancellation:

```swift
src: fromCallback { scope in
    let token = NotificationCenter.default.addObserver(
        forName: .somethingChanged, object: nil, queue: nil
    ) { _ in
        scope.sendBack(Event("CHANGED"))
    }
    return { NotificationCenter.default.removeObserver(token) }   // cleanup
}
```

The parent handles those events with ordinary `on:` transitions.

## `fromTaskGroup` — concurrent fan-out

When you need to run several async operations at once and act on the **collection** of results,
`fromTaskGroup` runs them concurrently and completes when they all finish. Its `onDone` output is
an **array**:

```swift
"fetchingAll": StateNodeConfig(
    invoke: [
        InvokeConfig(
            id: "batch",
            src: fromTaskGroup { scope in
                try await scope.runGroup([
                    { try await fetch(a) },
                    { try await fetch(b) },
                    { try await fetch(c) },
                ])
            },
            onDone: .single(TransitionConfig(
                target: "done",
                actions: [assign { ctx, args in
                    if let e = args.event as? DoneActorEvent,
                       let results = e.output?.get([Int].self) {
                        ctx.total = results.reduce(0, +)
                    }
                }]
            ))
        )
    ]
)
```

``TaskGroupScope/runGroup(_:)`` collects results in completion order and honors cancellation
between operations. If you want to stream partial progress instead of waiting for the whole
batch, build your own `withThrowingTaskGroup` inside the closure and use `scope.sendToParent(_:)`
as each operation lands.

## Invoking a child machine

`src:` can also be another state machine. Its `output` (set when it reaches a top-level final
state) becomes the `onDone` event's output — so machines compose like functions:

```swift
src: fromMachine(childMachine),
onDone: .to("childFinished")
```

## A note on cancellation

Because invoked logic is bound to a state, exiting that state cancels the work — no orphaned
tasks, no manual bookkeeping. `fromTask`/`fromTaskGroup` check `Task.checkCancellation()` and
run your `onCancel`; `fromCallback` runs the cleanup closure you returned. This is what makes
"start the request when entering `loading`, abandon it if the user navigates away" a one-liner
instead of a lifecycle headache.

## Next steps

- <doc:NamedImplementations> — register these actors by name so configs stay declarative and
  the inspector can label them.
- <doc:RunningActors> — how parents observe and message their children.
