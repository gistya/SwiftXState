# Driving SwiftUI

Wire a machine to your views with snappy, glitch-free updates — and know which of the three approaches to reach for.

## Overview

SwiftXState's ``Actor`` is a Swift `actor`, which means every `send` is a round trip *off* the main
actor and *back* before SwiftUI can read the new ``MachineSnapshot``. For most UI that round trip is
invisible. For latency-sensitive, high-frequency input — dragging a slider, typing, sketching on a
canvas — it shows up as lag: the view repaints a runloop turn late.

There are three ways to drive SwiftUI, trading completeness for immediacy:

| Approach | Updates | Use when |
|----------|---------|----------|
| **Synchronous `Store`** | inline, this runloop turn | view-model state that doesn't need the full statechart |
| **Main-executor actor** | inline, no thread hop | full statechart, light transition work, low latency wanted |
| **Optimistic driver** | inline (predicted), reconciled async | full statechart + heavy/async work, but input must feel instant |

The first is the recommended default; the other two are for when you need the full machine *and* the
latency gone.

> Note: All three live in the `SwiftXStateSwiftUI` module (Apple platforms). `import SwiftXState`
> and `import SwiftXStateSwiftUI`.

## The synchronous store (recommended)

A ``Store`` is XState's lightweight reducer: `context` plus event handlers, with **no** invoke,
spawn, `after`, or nested states. It runs **synchronously on whatever thread calls it** — the main
thread, for UI — so `send` mutates and `snapshot` reads inline, with no actor, no `await`, and no
hop. SwiftUI sees the new value the same turn the button fires.

```swift
import SwiftXState
import SwiftXStateSwiftUI

enum CounterEvent: String, Eventable {
    case increment, decrement
    var type: String { rawValue }
}

struct CounterContext: Sendable, Equatable { var count = 0 }

let counterStore = createStore(
    context: CounterContext(),
    on: [
        "increment": { ctx, _ in ctx.count += 1 },
        "decrement": { ctx, _ in ctx.count -= 1 },
    ]
)
```

Bind it with the `@StoreState` property wrapper. Its wrapped value is the ``StoreSnapshot``; its
projected value (`$`) is the driver you `send` through:

```swift
struct CounterView: View {
    @StoreState(counterStore) private var state

    var body: some View {
        HStack {
            Button("–") { $state.send(.decrement) }
            Text("\(state.context.count)")
            Button("+") { $state.send(.increment) }
        }
    }
}
```

`useStore(_:)` is the closure-style equivalent if you prefer it over the wrapper.

**Reach for the store when** the state is local to a view or screen and you don't need statechart
machinery — toggles, forms, counters, wizard steps, derived view models. It's the cheapest path and
the only one with zero async surface. When you outgrow it (you want `invoke`, child actors, `after`,
or hierarchical states), move up to a full machine — the two share the same event/assign mental
model.

## A full machine, and its latency

The full statechart runs as an ``Actor``. The `@MachineState` wrapper drives it for you:

```swift
struct LightView: View {
    @MachineState(trafficLight) private var snapshot

    var body: some View {
        Button(snapshot.value.description) { $snapshot.send(Event("TIMER")) }
    }
}
```

`$snapshot.send(_:)` is fire-and-forget: it hands the event to the actor on a background executor
and the view updates a turn later when the actor's snapshot comes back. That's correct and fine for
ordinary taps — but it's the round trip described above. The next two approaches remove it.

## Removing the thread hop: a main-executor actor

Set ``ActorOptions/useMainExecutor`` to run the actor on the **MainActor's** serial executor instead
of its own background queue. `send` / `snapshot` are still `async`, but called *from* the main actor
there's no thread hop — the transition runs inline and SwiftUI sees the result without bouncing
through a background thread.

```swift
let actor = createActor(machine, options: ActorOptions(useMainExecutor: true))
```

```swift
@MainActor @Observable
final class LightModel {
    private(set) var snapshot: MachineSnapshot<LightContext>
    private let actor: Actor<MachineLogic<LightContext>>

    init() {
        actor = createActor(trafficLight, options: ActorOptions(useMainExecutor: true))
        snapshot = initialTransition(trafficLight).snapshot
    }

    func start() async {
        await actor.start()
        snapshot = await actor.snapshot
        _ = await actor.subscribe { snap in
            Task { @MainActor in self.snapshot = snap }
        }
    }

    func send(_ event: any Eventable) async {
        await actor.send(event)
        snapshot = await actor.snapshot
    }
}
```

**Reach for this when** you want the *whole* statechart with minimal UI latency and the transition
work is light. The trade-off is in the name: the actor's work now runs on the main thread, so it's
the wrong choice if a transition kicks off heavy synchronous work or you specifically wanted that
logic off-main. (Darwin-only; on platforms without `Darwin` the flag is ignored and the actor keeps
its default executor.)

## Hiding latency: optimistic prediction

When you need the full machine *and* heavy/async work *and* instant feedback, keep the actor on its
background executor and put an `OptimisticMachineDriver` in front of it. For the events you opt in
to, it predicts the result **synchronously on the main actor** and publishes it immediately, then
lets the actor compute the authoritative snapshot and reconciles.

The prediction isn't a hand-written mirror — it reuses the machine's own pure
``transition(_:snapshot:event:)``, so a predicted snapshot can't diverge from what the actor will
independently compute (side effects aside, which only ever run on the actor).

```swift
@MainActor @Observable
final class CanvasModel {
    let driver: OptimisticMachineDriver<CanvasContext>

    init() {
        driver = OptimisticMachineDriver(canvasMachine) { event in
            // Predict only deterministic, side-effect-free events — here, strokes.
            if case .stroke = event as? CanvasEvent { return true }
            return false
        }
    }
}
```

```swift
driver.send(.stroke(x, y))   // canvas repaints this turn; the actor catches up in the background
```

The driver tracks predicted-but-unconfirmed events and always publishes `confirmed` with the pending
predictions replayed on top, so a late confirmation can't clobber edits the user made *after* it
during a fast drag.

> Important: Only predict events whose transition is **deterministic** and side-effect-free in its
> context effect. Predicting a non-deterministic event (e.g. an `assign` using `random`) or one whose
> result depends on async work makes the prediction briefly disagree with the actor, and the UI
> flickers on reconcile. `predict` defaults to predicting nothing, in which case the driver behaves
> like a serialized background-actor driver.

The two knobs compose: pass an actor you built with `useMainExecutor: true` to
`OptimisticMachineDriver(_:actor:snapshot:predict:)` if you want both.

## Choosing

- **Start with the ``Store``.** If the state is local UI state and you don't need statechart
  features, you're done — synchronous, no async, no latency.
- **Use a main-executor actor** when you need the full machine, the work is light, and you want the
  hop gone with the least machinery.
- **Use `OptimisticMachineDriver`** when you need the full machine, the work is heavy or async, and
  high-frequency input still has to feel instant.

## Topics

### Synchronous store

- ``Store``
- ``StoreSnapshot``
- ``createStore(context:on:assign:)``

### Actor-backed bindings

- ``Actor``
- ``ActorOptions``
