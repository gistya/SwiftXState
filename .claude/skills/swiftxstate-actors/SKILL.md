---
name: swiftxstate-actors
description: Multi-actor orchestration in SwiftXState — spawning child machines (enq.spawn), typed cross-actor messaging (enq.sendTo with payloads), Invoke, child lifecycle (stopChild, onDone), parent/child communication, actor ids and systemIds. Use when one machine must own, command, or observe other machines.
---

# Multi-actor systems (spawn / sendTo / invoke)

An actor can own a tree of child actors. Two ways to create them:

## 1. `enq.spawn` — dynamic children (any handler or entry)

```swift
State(.boot) { Always(to: .game) }
    .initial()
    .onEntry { args, enq in
        for square in args.context.layout.squares {
            enq.spawn(
                SquareMachine(),
                id: BoardIds.square(square.coord),        // stable child id — the address for sendTo
                context: SquareContext(coord: square.coord, occupantId: square.occupantId),
                systemId: SquareMachine.id,               // groups instances for inspection
                inspectable: false                        // see swiftxstate-performance
            )
        }
        return args.context
    }
```

- Per-instance seeding via the `context:` override (no input plumbing needed).
- Spawning from the machine's **initial** entry works (engine flattens entry actions on start).
- `enq.stopChild("id")` stops + removes; stop all on reset by iterating known ids.

## 2. `Invoke` — declarative children tied to a state's lifetime

```swift
State(.loading) {
    Invoke(id: "fetch", source: fromTask { try await api.load() })
        .onDone(to: .loaded, action: { output, ctx in ... })   // output = task result
        .onError(to: .failed)
    Transition(on: .cancel, to: .idle)                          // exiting the state cancels the invoke
}
```

`ActorSource` factories: `fromMachine` (child statechart), `fromTask`, `fromTaskGroup`,
`fromCallback`, `fromObservable`, `fromTransition`, `fromStore` — see swiftxstate-tasks for the
async ones.

## Typed cross-actor messaging — payloads survive

```swift
enq.sendTo(squareId, SquareEvent.occupy(pieceId: id))   // a CHILD machine's own event type + payload
enq.sendTo(childId, EventID.someCase)                   // parent's own event family also fine
```

The event is delivered verbatim as a `TypedEvent<ChildEvent>`; the child reads the payload off
`args.event` exactly like a direct send. (Old pattern of encoding payloads in the type string —
`Event("OCCUPY.\(id)")` — is obsolete for typed machines.) `enq.raise` (self) carries the
**discriminant only** — don't raise payload cases expecting data.

Child → parent: `sendToParent` action (engine layer) / done-output via `.final()` + `OnDone` /
`onSnapshot` observation. Deliveries to the parent are serialized (no done-before-send races).

## Ids

- **child id** — the address (`enq.sendTo`, `actor.childActor(id:)`); make it deterministic
  (`"square.e4"`, `"piece.wPe2"`); collect them (e.g. a `layout.allChildIds`) so reset can stopChild all.
- **systemId** — stable type/group label used by inspection.
- Reading a child from outside: `await parentActor.childActor(id:) as? MachineChildRef<ChildContext>`
  then `child.actor.snapshot`. NOTE: `snapshot.children[id]?.value` is unreliable even with
  `syncSnapshot: true` — observe child *behavior* (its own snapshot / a side channel), not `.value`.

## The canonical example

`Examples/SwiftXChess`: `GameWatcherMachine` (orchestrator) spawns 64 square + 32 piece +
2 board-inspector children from boot entry (`BoardActorSpawn.spawnBoard`), fans out move commands
via typed `enq.sendTo` (`dispatch(_:into:)`), stops/respawns the tree on `newGame`.

## Reference files
- `Sources/SwiftXState/DSL/Spawn.swift`, `Enqueue.swift`, `Structural.swift` (Invoke)
- `Sources/SwiftXState/Actor/Global Funcs/from.swift` (+ `fromObservable.swift`)
- Tests: `Tests/SwiftXStateTests/DSLSpawnTests.swift`, `DSLCrossActorTests.swift`, `DSLGameWatcherStructureTests.swift`
