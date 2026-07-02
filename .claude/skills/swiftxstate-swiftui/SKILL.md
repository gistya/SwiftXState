---
name: swiftxstate-swiftui
description: Integrate SwiftXState machines with SwiftUI — MainStore, @Machine property wrapper, MachineView, bind() lens/prism bindings, MapStateDriver, OptimisticMachineDriver. Use when wiring a StateMachine to views, building observable app state, or replacing @State/ObservableObject business logic with statecharts.
---

# SwiftXState × SwiftUI (SwiftXStateSwiftUI module)

`import SwiftXStateSwiftUI` (gated `SWIFTXSTATE_APPLE_UI`). The design: **views render context and
send events; they never mutate state directly.** Every UI edit becomes an auditable event.

## The three tiers

1. **`@Machine`** — one machine, one view (like `@State` for a statechart):

```swift
struct CounterView: View {
    @Machine(CounterMachine()) var store    // note: @Machine(M()), NOT @Machine var x = M()

    var body: some View {
        Text("\(store.context.count)")
        Button("＋") { store.send(.increment(by: 1)) }
            .disabled(!store.matches(.active))
    }
}
```

2. **`MachineView`** — closure form receiving the current typed state:

```swift
MachineView(PlayerMachine()) { state, store in
    switch state {                     // state: M.StateID (first active atomic)
    case .playing: PauseButton { store.send(.pause) }
    case .paused:  PlayButton  { store.send(.play) }
    }
}
```

3. **`MainStore`** — the app-level collator: a `@MainActor @Observable` registry of any number of
   `MachineStore`s, keyed **by machine type** (or `MachineKey<M>("name")` for multiple instances):

```swift
@Observable @MainActor final class AppModel {
    let main = MainStore()
    init() {
        main.track(SessionMachine())
        main.track(PlayerMachine(), key: MachineKey<PlayerMachine>("mini-player"))
    }
}
// anywhere:
let player = model.main.store(PlayerMachine.self)        // typed lookup, no strings
let mini   = model.main.store(MachineKey<PlayerMachine>("mini-player"))
```

`MachineStore<M>` surface: `context`, `configuration`, `status`, `send(_ id:)`, `matches(_:)`,
`matches(path:)` — all main-actor observable; the actor runs off-main and snapshots hop back.

## Two-way bindings — bind() (lens read / prism write)

```swift
TextField("Name", text: store.bind(\.name, send: FormEvent.setName))     // KeyPath in, event case out
Slider(value: store.bind(\.volume, send: AudioEvent.setVolume), in: 0...1)
Toggle("Playing", isOn: store.bind(.playing, on: .play, off: .pause))    // state-driven Bool
```

The `send:` argument is a payload case initializer (`(String) -> FormEvent`) — spell the type
(`FormEvent.setName`), leading-dot won't infer unapplied payload cases.

## Derived view state

- `useMapState(...)` / `MapStateDriver` — project a snapshot into a view-facing value with a
  `StateMap` (per-state mapping), observable.
- `OptimisticMachineDriver` — optimistic UI: `snapshot` reflects sends immediately, `confirmed`
  trails the actor; use for latency-sensitive controls.

## Rules of thumb

- Views read `store.context` for data and `store.matches(...)` for mode — don't stash machine
  state in `@State`.
- Send events, never mutate: if you're tempted to write `context.x = y`, add an event + action.
- One `MainStore` at the app root; feature views take the specific `MachineStore<M>` they need.
- The underlying `MachineActor`/engine actor is reachable when you need inspection or graphing:
  see the swiftxstate-inspection skill.

## Reference files
- `Sources/SwiftXStateSwiftUI/` (MainStore, MachineView, Bindings, UseMapState, OptimisticMachineDriver)
- Example app: `Examples/XConway` (full @Machine + bind + MachineView usage)
- Tests: `Tests/SwiftXStateSwiftUITests/` (MainStoreTests, MachineViewTests, BindingTests, XConwayPatternTests)
- Docs: `Sources/SwiftXState/SwiftXState.docc/DrivingSwiftUI.md`
