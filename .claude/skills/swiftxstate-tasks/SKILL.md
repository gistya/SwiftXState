---
name: swiftxstate-tasks
description: Long-running and parallel async work with SwiftXState — fromTask, fromTaskGroup, fromCallback, fromObservable child actors, Invoke onDone/onError/onSnapshot, cancellation via state exit, progress streaming. Use when a machine must run network calls, downloads, batch jobs, or fan-out concurrent work.
---

# Async work: task & taskGroup children

Never `await` long work inside an `.action` (it stalls the actor's mailbox). Model the work as a
**child actor** whose lifecycle is a state; the machine reacts to its completion/failure/output.

## One-shot async — `fromTask`

```swift
State(.loading) {
    Invoke(id: "fetch", source: fromTask { try await api.fetchUser() })
        .onDone(to: .loaded, action: { output, ctx in     // output: the task's return (Sendable & Equatable)
            var c = ctx; c.user = output?.get(User.self); return c
        })
        .onError(to: .failed, action: { error, ctx in
            var c = ctx; c.message = String(describing: error); return c
        })
    Transition(on: .cancel, to: .idle)     // leaving .loading CANCELS the task (structured)
}
```

Cancellation is structural: exiting the invoking state cancels the child task. Honor
`Task.checkCancellation()` inside the closure for prompt teardown.

## Parallel fan-out — `fromTaskGroup`

`fromTaskGroup { group in ... }` runs a task group as one child; return the combined output. Use for
"process N items concurrently, then transition":

```swift
Invoke(id: "thumbnails", source: fromTaskGroup { 
    // add per-item tasks, collect results, return Sendable summary
})
.onDone(to: .ready)
```

For *independently addressable* concurrent workers (pause/cancel one, stream per-worker progress),
prefer N spawned `fromTask`/`fromMachine` children with their own ids (see swiftxstate-actors) over
one opaque group.

## Streams & callbacks

- `fromObservable { ... }` — a child that emits a stream of context values; `.onSnapshot(to:)` /
  snapshot observation feeds each element back into the machine (progress %, download bytes,
  playback position).
- `fromCallback { send in ... }` — bridge delegate/callback APIs: hold the `send` and call it as
  events arrive (e.g. a URLSession delegate, a hardware event source).
- `fromTransition` / `fromStore` — lightweight reducer children (context-only actors, no chart).

## Patterns

- **Progress**: context field (`progress: Double`) patched from `onSnapshot`; UI binds to it.
- **Retry**: `failed` state + `After(.seconds(n), to: .loading)` (backoff via a context attempt
  counter feeding a computed delay) + `Transition(on: .retry, to: .loading)`.
- **Serial queue of jobs**: compound state cycling `idle → running → idle` with a queue in context;
  `Always(to: .running).when { !$0.queue.isEmpty }`.
- **Long-lived engines** (audio, sockets): a spawned `fromCallback`/`fromMachine` child that outlives
  individual states — spawn at boot, address with `enq.sendTo`, stop at teardown.

## Reference files
- `Sources/SwiftXState/Actor/Global Funcs/from.swift`, `fromObservable.swift`
- `Sources/SwiftXState/DSL/Structural.swift` (Invoke: onDone/onError/onSnapshot/input)
- Docs: `Sources/SwiftXState/SwiftXState.docc/AsyncWork.md`
- Tests: `Tests/SwiftXStateTests/` (invoke + child-migration suites cover every source kind)
