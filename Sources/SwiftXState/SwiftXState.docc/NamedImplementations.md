# Named Implementations with setup

Pull inline guards, actions, delays, and actors out of the config and register them by name.

## Overview

Inline closures are great for getting started, but as a machine grows you'll want to:

- **reuse** the same guard or action in several places,
- keep the config **declarative** (structure in one place, behavior in another),
- give your actors **stable names** so the inspector and Stately tooling can label them,
- and (eventually) load a machine's **structure from JSON** while supplying behavior in Swift.

``setup(actions:guards:delays:actors:)`` is how. It mirrors XState's `setup({...}).createMachine({...})`:
you register named implementations once, then refer to them by string in the config.

## The pattern

```swift
struct LightContext: Sendable, Equatable {
    var elapsed: Int
}

let machine = setup(
    guards: [
        "minTimeElapsed": { args in
            args.context.elapsed >= 100 && args.context.elapsed < 200
        },
    ]
).createMachine(MachineConfig(
    initial: "green",
    context: LightContext(elapsed: 0),
    states: [
        "green": StateNodeConfig(on: [
            "TIMER": .to("yellow"),
        ]),
        "yellow": StateNodeConfig(on: [
            "TIMER": .single(TransitionConfig(
                target: "red",
                guard: .named("minTimeElapsed")     // ← resolved from setup
            )),
        ]),
        "red": StateNodeConfig(),
    ]
))
```

The config references `guard: .named("minTimeElapsed")`; ``setup(actions:guards:delays:actors:)``
supplies the actual predicate. The config no longer contains behavior — just structure and the
names of the behaviors it needs.

## The four kinds you can register

| Parameter | Referenced by | Used for |
|---|---|---|
| `actions` | `.named("…")` in an `actions:` list | Reusable side effects |
| `guards` | `.named("…")` as a transition `guard:` | Reusable predicates |
| `delays` | a delay name in `after:` | Named timeouts (ms) |
| `actors` | `src:` of an `invoke` / `spawnChild` | Named actor logic |

```swift
setup(
    actions: [
        "logIt": { args in print("event: \(args.event.type)") },
    ],
    guards: [
        "isReady": { $0.context.ready },
    ],
    delays: [
        "shortPause": { _ in 250 },     // milliseconds
    ],
    actors: [
        "loader": ActorLogicEntry(task: .init(/* fromTask logic */)),
    ]
)
```

A named delay is then used like `after: ["shortPause": .to("next")]`, and a named actor like
`InvokeConfig(id: "load", src: .named("loader"), onDone: .to("ready"))`.

## Providing or overriding later

If you build a machine without all its implementations — or want to swap them in a test — use
``StateMachine/provide(_:)`` to layer in a ``MachineImplementations`` value. Later registrations
win, so you can override a single guard while keeping the rest:

```swift
let testMachine = machine.provide(MachineImplementations(
    guards: ["minTimeElapsed": { _ in true }]   // force the branch in a test
))
```

## Why this matters for tooling

Named actors are what let the **inspector** and Stately's registry display meaningful labels
(`"loader"`, `"game-watcher"`) instead of anonymous closures, and they're the seam that lets a
machine's *structure* come from exported/imported JSON while its *behavior* stays in type-checked
Swift. If you plan to visualize or share your machines, prefer named implementations.

## Next steps

- <doc:AsyncWork> — the actor logic (`fromTask` etc.) you'll register under `actors:`.
- <doc:RunningActors> — running the machine you just set up.
