---
name: swiftxstate-transitions
description: Advanced SwiftXState transitions — context and event-aware guards (.when), eventless Always chains (choice states), After delays, onDone/onError, wildcard events, self-targets vs internal transitions, run-to-completion semantics. Use when a transition needs conditions, timing, or isn't firing as expected.
---

# Advanced transitions & guards

## Guards — `.when`

Two arities; the resolver AND-combines case-match + context guard + event guard into one engine guard:

```swift
Transition(on: .submit, to: .sending)
    .when { ctx in ctx.isValid }                          // context-only

Transition(on: ChessEvent.tap, to: .forfeited)
    .when { ctx, event in                                 // EVENT-AWARE (two-arg) — reads the payload
        guard case let .tap(square)? = event,
              let move = Rules.pendingMove(ctx, to: square) else { return false }
        return move.forfeitsCastling
    }
```

Guards must be pure `@Sendable` predicates — no effects (effects belong in `.action`'s `enq`).

## Eventless transitions — `Always` (v6 choice-state)

`Always(to:).when {}` fires whenever the state is entered or context changes, first match wins in
declaration order. This replaces XState v5 choice states and "derived state" flags:

```swift
State(.idle) {
    Always(to: .selecting).when { $0.selected != nil && $0.pendingPromotion == nil }
    Always(to: .promoting).when { $0.pendingPromotion != nil }
}.initial()
```

Pattern: make substates **pure functions of context** — handlers only patch context; the Always
chain re-derives the position. Then a handler can self-target the parent
(`Transition(on: Ev.tap, to: .turn)`) and behave like an internal transition (momentary re-entry is
immediately re-derived; safe when the parent has no entry/exit actions).

## Delays — `After`

```swift
State(.buffering) {
    After(.seconds(5), to: .stalled)          // cancelled automatically on state exit
    Transition(on: .buffered, to: .playing)
}
```

Timers use `ActorOptions.clock` — inject a test clock for deterministic tests.

## Done / error — `OnDone`, `Invoke.onDone/.onError`

- A child state hierarchy reaching a `.final()` state fires the parent's `OnDone(to:)`.
- `.output { ctx in SendableValue(...) }` on the final state provides done-output; read it via the
  onDone transition's output action (`DoneStateEvent` / `DoneActorEvent .output`).
- `Invoke(...).onDone(to:)/.onError(to:)/.onSnapshot(to:)` for invoked children (see swiftxstate-tasks).

## Targets — how `to:` resolves

- **Unique state name** anywhere in the tree → resolves absolutely; deep cross-branch jumps work
  (`to: .idle` from `replaying`, landing on `game.active.turn.idle`).
- **Shared name** (several regions each have `available`) → resolves among siblings/children only —
  each region's transition lands in its own copy.
- String machines can target with dotted/`#` paths and match events by wildcard (`"SAN.*"`).

## Run-to-completion (RTC)

One event = one macrostep: guard evaluation → transition → context patch → collected `enq` effects →
Always chains settle → next queued event. `enq.raise` queues for the NEXT macrostep (never re-enters
the current one). If a transition "isn't firing": check (1) declaration order of competing
transitions/Always (first match wins), (2) whether a guard reads stale context (guards see the
context *before* this event's patch), (3) whether the event's case-init matches (payload cases route
by CasePath — `Transition(on: Ev.tap, ...)` with the type spelled out).

## Reference tests (worked examples of every feature)
- `Tests/SwiftXStateTests/DSLEventGuardTests.swift` (event-aware guards)
- `Tests/SwiftXStateTests/DSLChessStructureTests.swift` (Always chains, parallel isolation)
- `Tests/SwiftXStateTests/DSLAbsoluteTargetTests.swift` (cross-branch targets)
- `Tests/SwiftXStateTests/DSLGameWatcherStructureTests.swift` (self-target ≈ internal + play loop)
