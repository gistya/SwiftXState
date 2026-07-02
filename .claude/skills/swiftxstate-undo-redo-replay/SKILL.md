---
name: swiftxstate-undo-redo-replay
description: Undo/redo, time-travel, and session replay with SwiftXState — InspectionRecorder, ReplaySession, timeTravel, verifyReplay, recording gates, scrub UIs, capture/restore of live state. Use when implementing undo, redo, a replay scrubber, deterministic session playback, or verifying recorded behavior.
---

# Undo / redo / replay / time-travel

The engine is deterministic: **state = fold(events over machine)**. Record the events; any past
state is recomputable. No memento stacks needed.

## Recording

```swift
let recorder = InspectionRecorder()
let actor = createActor(machine, options: ActorOptions(inspect: recorder.observe()))
// … user plays …
let session: ReplaySession? = recorder.session()    // steps: [event + snapshotAfter]
```

Gate recording so replay/scrub events don't pollute the history (SwiftXChess's
`ReplayRecordingGate` pattern — a locked bool wrapping `recorder.observe()`): disable on
enter-replay, re-enable on exit/new-game. Combine multiple observers by fanning one closure out.

## Time-travel (the undo/redo primitive)

```swift
let past = timeTravel(machine, context: .initial(), session: session, toStep: k)  // MachineSnapshot?
// undo  = timeTravel(toStep: current - 1)
// redo  = timeTravel(toStep: current + 1)
```

`timeTravel` re-runs the machine from scratch through step k — pure, no actor involved. For big
sessions, steps also carry `snapshotAfter` (decode it directly — SwiftXChess's
`ChessReplayRestore.playableContext(from:)` — and fall back to timeTravel when absent/undecodable).

## Undo/redo recipe

1. Keep `recorder` + a cursor (`step`) in your session object; each *user* event advances the end.
2. Undo/redo: move the cursor, compute the snapshot via `timeTravel`/decoded step, patch the live
   actor's context via a dedicated restore event (never mutate behind the actor's back).
3. New user action while undone → truncate: start a fresh recorder seeded from the cursor state.

## Replay scrubber (the full pattern, from SwiftXChess)

- `enterReplay`: freeze `recorder.session()` into context (`replaySession`), **capture the live
  snapshot** (context self-snapshot fields), disable recording.
- `replayScrub(step)`: clamp; skip no-ops (`guard clamped != context.replayStep`); restore board
  from `session.steps[clamped]`.
- `exitReplay`: clear session, **restore the captured live snapshot**, re-enable recording.
- Model replaying as a *state* (`playing / replaying`) so guards can block normal input during replay.

## Verification & persistence

- `verifyReplay(machine, context: .initial(), session: session)` — re-runs and diffs every step
  against the recorded snapshots (`results.allSatisfy(\.matches)`); use in tests and as a
  crash-recovery integrity check.
- Persist sessions with `ReplayPersistenceStore` (SwiftData) — see swiftxstate-persistence.

## Determinism requirements

Handlers must be pure functions of (context, event): no `Date()`, no `random()`, no reads of
ambient globals inside actions — inject via events/context. Anything nondeterministic breaks
timeTravel equivalence (verifyReplay will catch it).

## Reference files
- `Sources/SwiftXState/**/Replay.swift` (timeTravel, verifyReplay, transition, selectTransitions)
- `Examples/SwiftXChess/SwiftXChess/ChessMachine.swift` (enter/exit/scrub handlers + capture/restore),
  `ChessReplayRestore.swift`, `DistributedChessSession.swift` (recording gate)
- Tests: `Examples/SwiftXChess/SwiftXChessTests/SwiftXChessReplayIntegrationTests.swift`
