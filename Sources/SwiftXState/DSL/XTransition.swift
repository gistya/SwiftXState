import CompositionalInit

/// A single transition declaration: on `event`, go `to` a target state — refined with the chainable
/// `.when(_:)` guard and `.action(_:)` context transform.
///
/// ```swift
/// XTransition(on: .stop, to: .red)
///     .when { ctx in ctx.cyclesOk }
///     .action { ctx in ctx.incrementingCycles() }
///
/// // payload event — reference the case itself, no placeholder value:
/// XTransition(on: CounterEvent.increment, to: .active)
///     .action { args, _ in
///         guard case let .increment(by)? = args.event else { return args.context }
///         return args.context + by
///     }
/// ```
public struct XTransition<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: Sendable, Cloneable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public var node: Schema.TransitionNode

    init(node: Schema.TransitionNode) {
        self.node = node
    }

    public init(on event: EventID, to target: StateID) {
        node = Schema.TransitionNode(event: event, target: target, guard: nil, action: nil)
    }

    /// Route a **payload-carrying** event by its case path — `XTransition(on: CasePath(Event.increment), to: …)`.
    /// No placeholder associated value: the transition is registered under the wildcard event and
    /// taken only when the incoming event matches this case. Read the payload, typed, via `args.event`.
    public init<Payload>(on casePath: CasePath<EventID, Payload>, to target: StateID) {
        let match: @Sendable (EventID) -> Bool = { casePath.extract($0) != nil }
        node = Schema.TransitionNode(event: nil, caseMatch: match, target: target)
    }

    /// Route a payload event by its **case initializer** — `XTransition(on: CounterEvent.increment, to: …)`.
    /// The cleanest form: pass the unapplied case (`Event.increment`); the case path is derived by
    /// reflection (`EventID: Equatable`, which every `EventIdentifying` is). Registers under the wildcard
    /// `*` (no recoverable case name); prefer the `Blankable`-payload overloads below, which name it.
    public init<Payload>(on caseInit: @escaping @Sendable (Payload) -> EventID, to target: StateID) {
        self.init(on: CasePath(caseInit), to: target)
    }

    // MARK: Named payload events (Blankable components → the case name is recoverable)
    //
    // When the payload component types are `Blankable`, construct a sample of the case and read its name
    // via `Mirror` (`.name`), so the transition routes under `"increment"` instead of `*` — visible in
    // the engine, the exported definition JSON, and the inspector graph. The sample is discarded; its
    // value never matters. One overload per associated-value arity (a tuple can't be one generic param).
    //
    // These MUST keep `@escaping @Sendable` even though the closure is only called here and never
    // stored: the arity-1 overload competes with the single-`Payload` wildcard overload above (which
    // genuinely stores the closure and so must be `@Sendable`), and overload resolution only prefers the
    // more-specialized `Blankable` overload when the two share the same function-type shape. Drop the
    // attributes and a 1-value payload case silently falls back to the wildcard `*`.

    /// One associated value: `XTransition(on: SoundtrackEvent.setVolume, to: …)`.
    public init<A: Blankable>(on caseInit: @escaping @Sendable (A) -> EventID, to target: StateID) {
        node = Schema.TransitionNode(event: nil, eventName: caseInit(A._blank).name, target: target)
    }

    /// Two associated values: `XTransition(on: SoundtrackEvent.setInsertSlot, to: …)`.
    public init<A: Blankable, B: Blankable>(on caseInit: @escaping @Sendable (A, B) -> EventID, to target: StateID) {
        node = Schema.TransitionNode(event: nil, eventName: caseInit(A._blank, B._blank).name, target: target)
    }

    /// Three associated values: `XTransition(on: SoundtrackEvent.playbackPrepared, to: …)`.
    public init<A: Blankable, B: Blankable, C: Blankable>(on caseInit: @escaping @Sendable (A, B, C) -> EventID, to target: StateID) {
        node = Schema.TransitionNode(event: nil, eventName: caseInit(A._blank, B._blank, C._blank).name, target: target)
    }

    /// Four associated values.
    public init<A: Blankable, B: Blankable, C: Blankable, D: Blankable>(on caseInit: @escaping @Sendable (A, B, C, D) -> EventID, to target: StateID) {
        node = Schema.TransitionNode(event: nil, eventName: caseInit(A._blank, B._blank, C._blank, D._blank).name, target: target)
    }

    /// Only take this transition when the predicate holds (context-only).
    public func when(_ predicate: @escaping Schema.Guard) -> Self {
        clone(mutating: \.node.`guard` <- predicate)
    }

    /// Only take this transition when the predicate holds — **event-aware**, XState's
    /// `({ context, event }) => bool`. The two-argument closure (`{ ctx, event in … }`) disambiguates
    /// it from the context-only form; `event` is the typed triggering event (`nil` for system events).
    public func when(_ predicate: @escaping @Sendable (Context, EventID?) -> Bool) -> Self {
        clone(mutating: \.node.eventGuard <- predicate)
    }

    /// Apply a pure context transform as the transition is taken (no effects).
    public func action(_ transform: @escaping Schema.Action) -> Self {
        let handler: Schema.Handler = { args, _ in transform(args.context) }
        return clone(mutating: \.node.action <- handler)
    }

    /// Apply an effectful handler as the transition is taken — XState v6's `(args, enq) -> context`.
    /// Return the next context; `raise` / `sendTo` / `emit` through `enq`.
    public func action(_ handler: @escaping Schema.Handler) -> Self {
        clone(mutating: \.node.action <- handler)
    }
}

// MARK: Workaroud for compiler issue.

// See Swift Evolution pitch:
// https://forums.swift.org/t/pitch-implicit-member-expressions-for-function-typed-parameters/87892/6

/// Workaround for Swift compiler inference limitation described in this Swift evolution pitch:
/// https://forums.swift.org/t/pitch-implicit-member-expressions-for-function-typed-parameters/87892/6
///
/// Due to the above limitation of the compiler, for  any `myEvent` case that has associated value(s),
/// you will not be able to simply use the dot-syntax `Transition(on: .myEvent, ...)` but instead
/// you will have to use `Transition(on: MyEvent.myEvent, ...)`, unless you use the following
/// workaround.
///
/// ## Workaround
///
/// In your `StateMachine` implementation, add an extension like so:
/// ```swift
/// extension Map where In == Int, Out == MyEvent {
///     static var myEvent: Map<(REPLACE_THIS_WITH_YOUR_PAYLOAD_TYPE), MyEvent> {
///         .init(transform: MyEvent.myEvent)
///     }
/// }
/// ```
///
/// Thenceforth you shall be able to `Transition(on: .myEvent, ...)` without compiler errors.
/// Thanks to fellow Austinite Rob Mayoff for this workaround!

public struct Map<In, Out> {
    public let transform: @Sendable (In) -> Out
    public init(transform: @Sendable @escaping (In) -> Out) {
        self.transform = transform
    }
}

public extension XTransition {
    init<Payload: Blankable>(on map: Map<Payload, EventID>, to target: StateID) {
        self.init(on: map.transform, to: target)
    }

    // Multi-value payload events: the case's associated values collapse into one tuple `In`,
    // and a tuple can't be Blankable, so the scalar overload above can't name it. Build a blank
    // tuple from the per-element Blankable pack, feed it through transform, read the case's .name
    // → "audioFailed" instead of "*". Same `Map` type, so `.audioFailed` dot-syntax matches it.
    init<each Payload: Blankable>(on map: Map<(repeat each Payload), EventID>, to target: StateID) {
        node = Schema.TransitionNode(
            event: nil,
            eventName: map.transform((repeat (each Payload)._blank)).name,
            target: target
        )
    }
}
