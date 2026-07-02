---
name: swiftxstate-media-streaming
description: Model media playback and recording with SwiftXState — player/recorder statecharts (loading/buffering/playing/seeking), AVPlayer/AVAudioEngine bridging via fromCallback/fromObservable children, position streaming, interruption handling, transport UI bindings. Use when building music/video players, recorders, or any streaming-pipeline state management.
---

# Media streaming state machines

Media is where ad-hoc flag soup (`isPlaying && !isBuffering && seekTarget == nil…`) breaks down.
Model the transport as a statechart; keep the AV engine behind a child actor.

## The canonical player machine

```swift
enum PlayerState: String, StateIdentifying {
    case idle, loading, ready, playing, paused, buffering, seeking, failed, ended
    static var _blank: PlayerState { .idle }
}
enum PlayerEvent: EventIdentifying {
    case load(url: URL), loaded(duration: Double), play, pause, seek(to: Double), seeked
    case buffered, stalled, tick(position: Double), finished, failed(message: String), stop
    static var _blank: PlayerEvent { .stop }
}

struct PlayerMachine: StateMachine {
    // context: url, duration, position, rate, error — SMALL (see swiftxstate-performance)
    var machine: some XStateMachine {
        State(.idle) { Transition(on: PlayerEvent.load, to: .loading) }.initial()
        State(.loading) {
            Invoke(id: "prepare", source: fromTask { try await engine.prepare(url) })
                .onDone(to: .ready).onError(to: .failed)
            After(.seconds(15), to: .failed)                       // load timeout, cancelled on exit
        }
        State(.ready)  { Transition(on: .play, to: .playing) }
        State(.playing) {
            Transition(on: .pause, to: .paused)
            Transition(on: .stalled, to: .buffering)
            Transition(on: PlayerEvent.seek, to: .seeking)
            Transition(on: .finished, to: .ended)
            Transition(on: PlayerEvent.tick, to: .playing).action { args, _ in   // self-target position update
                var c = args.context; if case let .tick(p)? = args.event { c.position = p }; return c
            }
        }
        State(.buffering) {
            Transition(on: .buffered, to: .playing)
            After(.seconds(10), to: .failed)                       // stall watchdog
        }
        State(.seeking) { Transition(on: .seeked, to: .playing) }
        State(.paused)  { Transition(on: .play, to: .playing); Transition(on: PlayerEvent.seek, to: .seeking) }
        State(.failed)  { Transition(on: .play, to: .loading) }    // retry re-prepares
        State(.ended)   { Transition(on: .play, to: .playing) }    // replay
    }
}
```

## Bridging the AV engine

The AVPlayer/AVAudioEngine object is a **reference type living outside context**. Bridge both ways:

- **Engine → machine**: a `fromCallback { send in ... }` child spawned at load — hook KVO /
  `AVPlayerItem` notifications / periodic time observer, translate to events (`.stalled`,
  `.buffered`, `.tick(position:)`, `.finished`). Or `fromObservable` for a value stream.
- **Machine → engine**: `enq.emit(EmittedEvent("PLAY"))` consumed by an `on(_:)` listener that owns
  the player, or command the engine in a session object after the send. Keep AV calls out of
  `.action` bodies (they're `@Sendable`, may hop threads; some AV APIs are main-bound —
  `ActorOptions.useMainExecutor` if you must run the machine on main).
- Coalesce ticks (~1–4 Hz for UI position; not every frame) and make `.tick` actors
  `inspectable: false` — see swiftxstate-performance.

## Interruptions, routes, focus

Add parallel regions rather than more flags (`isParallel` or a nested `.parallel()`):
`audioSession: {active, interrupted}` (phone call → pause + remember intent; end → resume if it was
playing), `route: {speaker, headphones, airplay}`. Event-aware guards decide resume behavior from
the payload (`.when { ctx, event in ... }`).

## Recorder

Same shape: `idle → preparing → recording ⇄ paused → finishing → done/failed`, with a
`fromCallback` child for level metering (`.meter(db:)` self-target ticks) and `After` watchdogs on
`preparing`/`finishing`.

## Transport UI

```swift
Toggle("Play", isOn: store.bind(.playing, on: .play, off: .pause))
Slider(value: store.bind(\.position, send: PlayerEvent.seek), in: 0...store.context.duration)
Button("Retry") { store.send(.play) }.opacity(store.matches(.failed) ? 1 : 0)
```

Scrubbing: send `.seek` on drag *end* (or throttled), not per pixel; the `seeking` state naturally
debounces (ticks arriving in `.seeking` are ignored — no transition declared → no state churn).

## Related skills
swiftxstate-tasks (children), swiftxstate-swiftui (bind), swiftxstate-performance (ticks/context),
swiftxstate-transitions (After watchdogs, event-aware guards).
