---
name: swiftxstate-performance
description: SwiftXState performance tuning — which actors to make inspectable ON vs OFF, context design for hot paths (value-type size, Equatable cost, snapshot frequency), snapshotMicrosteps, resolved-machine caching, high-actor-count systems. Use when a machine-driven app stutters, allocates heavily, or scales to many actors/events.
---

# Performance tuning

## Inspection cost — `inspectable` ON vs OFF

Every inspectable actor streams registration/event/snapshot `InspectionEvent`s to all observers on
every macrostep. Rule: **orchestrators ON, fleets OFF.**

- ON: the few machines you debug by watching — the game/session orchestrator, the top-level flow.
- OFF (`inspectable: false` on `enq.spawn` / `ActorOptions.inspectable`): high-count or
  high-frequency children — per-cell/per-square actors, tick-driven machines, streaming probes.
- Reference point: SwiftXChess runs 96 board actors off-inspector by default; turning them on is a
  deliberate stress test (kills the Stately web client; the native inspector copes).
- `ActorOptions.snapshotMicrosteps` — extra snapshots per microstep, debugging only; keep off in
  production.
- The `inspect:` closure runs synchronously on the actor's hot path — keep observers O(1)
  (enqueue elsewhere), and don't attach recorders you're not using (replay recording gates exist
  for exactly this — see swiftxstate-undo-redo-replay).

## Context design (the #1 lever)

Context is copied across the actor boundary and diffed on **every snapshot**:

- Keep it a compact value type. Big blobs (images, buffers, full documents) do NOT belong in
  context — store an id/handle; keep the payload in a store/cache actor.
- Cheap `Equatable` matters: snapshot publishing and `fromStore`/`fromObservable` children compare
  contexts. A context holding a large array/dictionary pays O(n) per event. Consider small
  summaries (counts, hashes, cursors) over full collections when the collection lives elsewhere.
- Copy-on-write collections are fine *if handlers mutate in place once* (`var c = args.context;
  c.cells[i] = ...`) — avoid patterns that force repeated CoW copies inside one handler.
- Derive, don't store: anything computable from other fields should be a computed var (it never
  crosses the boundary) — and machine *modes* should be states, not context flags (states are free;
  flags force Always re-evaluation and inflate Equatable).

## Structure

- **Cache the resolved machine**: `machine.resolvedMachine(id:)` folds the whole schema — do it once
  (`static let/var resolved`, or the `NSLock`-guarded cache in
  `Examples/SwiftXChess/SwiftXChessOpenings/.../OpeningMoveTreeMachine.swift` for big data-driven
  trees with thousands of states).
- Many small actors beat one giant context: independent things (board squares, download slots)
  scale better as spawned children — each snapshot is tiny and independent (see swiftxstate-actors).
- Event rate: coalesce high-frequency input (scrub/drag) before `send` — one event per frame, not
  per delta; guard no-op sends (`guard clamped != context.replayStep else { return }`).
- Wildcard/string machines (`"SAN.*"`) match by prefix per event — fine at human rates; for
  tick-rate events prefer typed cases.

## Measuring

Attach a counting `inspect:` observer (events/sec per actor id) or run the native inspector's
Events tab (see swiftxstate-inspection) to find chatty actors before optimizing blindly.
