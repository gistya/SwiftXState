---
name: swiftxstate-dsl
description: Author state machines with the SwiftXState typed declarative DSL (Plan D) — StateMachine protocol, State/Transition builders, hierarchy, parallel regions, payload events, entry/exit, enq effects, data-driven machines. Use when writing or modifying any `StateMachine` conformance, machine body, or when DSL code fails to compile.
---

# SwiftXState typed DSL

The DSL is a typed authoring layer that **lowers onto the proven string engine** via the resolver
(`Sources/SwiftXState/DSL/Resolver.swift`). You declare machines like SwiftUI views; the engine runs
XState v5/v6 semantics unchanged.

## Minimal machine

```swift
struct TrafficLight: StateMachine {
    typealias Context = TrafficContext          // Sendable value type
    typealias StateID = Light                   // enum: StateIdentifying
    typealias EventID = LightEvent              // enum: EventIdentifying

    var context: TrafficContext { .init() }     // declared initial context (v6 createMachine({context}))

    var machine: some XStateMachine {
        State(.red)    { Transition(on: .go,      to: .green)  }.initial()
        State(.green)  { Transition(on: .caution, to: .yellow) }
        State(.yellow) { Transition(on: .stop,    to: .red)    }
    }
}

enum Light: String, StateIdentifying { case red, green, yellow; static var _blank: Light { .red } }
enum LightEvent: String, EventIdentifying { case go, caution, stop; static var _blank: LightEvent { .go } }
```

- `State`, `Transition`, `Always`, `After`, `OnDone`, `Invoke` are **member typealiases on the
  `StateMachine` protocol** (they infer `Context/EventID/StateID` from `Self`). Global spellings are
  `XState`, `XTransition`, `XAlways`, `XAfter`, `XOnDone`, `XInvoke` — use those in helper functions
  whose return type must be explicit: `func bootState() -> XState<Ctx, Ev, St>`.
- They do NOT collide with `SwiftUI.State`/`.Transition` — protocol members only shadow inside the
  conformer (proven by `Tests/SwiftXStateSwiftUITests/SwiftUINameCoexistenceTests.swift`).
- Every `StateID`/`EventID` enum needs `static var _blank` (identity anchor).

## Payload events

```swift
enum CounterEvent: EventIdentifying {
    case increment(by: Int), reset
    static var _blank: CounterEvent { .reset }
}

Transition(on: CounterEvent.increment, to: .active)   // route by CASE-INITIALIZER (CasePath)
    .action { args, _ in
        var ctx = args.context
        if case let .increment(by)? = args.event { ctx.count += by }   // typed payload off args.event
        return ctx
    }
```

**GOTCHA (Swift limitation):** leading-dot does not work for *unapplied payload cases* —
`Transition(on: .increment, ...)` fails with "type '(Int) -> E' has no member". Spell the type:
`CounterEvent.increment`. Payload-less cases can use leading-dot (`.reset`).

## Hierarchy, parallel, root-parallel

```swift
struct Chess: StateMachine {
    var isParallel: Bool { true }        // PARALLEL ROOT — all top-level regions run at once, no .initial()
    var machine: some XStateMachine {
        State(.game) {                   // compound region
            State(.playing) { ... }.initial()
            State(.gameOver) { ... }
        }
        State(.castling) {               // nested parallel region
            side(.wk); side(.wq); side(.bk); side(.bq)
        }.parallel()
    }
}
```

- Shared child names across regions (e.g. four sides each with `available`/`forfeited`) are fine —
  kept distinct by parent path; assert with `matches(path: "castling.wk.forfeited")`.
- **Transition targets:** a target whose name is *unique* in the tree resolves absolutely (deep
  cross-branch jumps like `replaying → game.active.turn.idle` just work: `to: .idle`). A *shared*
  name resolves relative to siblings only.
- `.final()` marks a final state; parent `OnDone(to:)` fires when reached. `.output { ctx in ... }`
  provides done-output (read via `onDone` output action).

## Entry / exit / effects (enq)

```swift
State(.boot) { Always(to: .ready) }
    .initial()
    .onEntry { args, enq in
        enq.spawn(ChildMachine(), id: "child-1", context: seedCtx)   // spawn works from initial entry
        enq.raise(.kick)                    // internal event, RTC-queued — DISCRIMINANT ONLY, no payload
        enq.sendTo("child-1", ChildEvent.configure(mode: .fast))     // typed cross-actor, PAYLOAD SURVIVES
        enq.emit(EmittedEvent("READY"))     // to external on(_:) listeners
        enq.stopChild("old-child")
        return args.context                 // handlers return the next context (v6 (args, enq) -> patch)
    }
```

`.action` has two forms: pure `{ ctx in newCtx }` and effectful `{ args, enq in ... return ctx }`.
Effects are collected, then run AFTER the context patch (run-to-completion safe).

## Data-driven machines (result-builder loops)

`StateID == String, EventID == String` is the untyped instantiation — build states in a `for` loop
(opening books, boards). See `Examples/SwiftXChess/.../OpeningMoveTreeMachine.swift` and
`BoardInspectorMachine.swift`.

**GOTCHA:** with String/String, `.action { context in }` can't infer Context — annotate:
`.action { (context: MyContext) in ... }`. Wildcard event strings work: `Transition(on: "SAN.*", to: ...)`.

## Running it

```swift
let actor = createActor(TrafficLight())      // MachineActor<TrafficLight>
await actor.start()                          // or .start(context: override)
await actor.send(.go)                        // typed send — no Eventable at call sites
_ = await actor.matches(.green)              // or matches(path: "a.b.c")
let cfg = await actor.configuration          // typed Configuration<StateID>
```

Need the engine (`ResolvedMachine`) for replay/inspection/graph? `machine.resolvedMachine(id: "x")`.
Cache it in a static (`static var resolved`) — resolution folds the whole schema.

## Reference files
- DSL sources: `Sources/SwiftXState/DSL/` (Schema, XState, XTransition, Structural, Resolver, MachineActor, Enqueue, Spawn)
- Worked examples: `Tests/SwiftXStateTests/DSL*.swift` (each feature has a focused test), `Examples/XConway`, `Examples/SwiftXChess`
- Docs: `Sources/SwiftXState/SwiftXState.docc/TypeSafeCoreConcepts.md`, `GettingStarted.md`
