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
    /// reflection (`EventID: Equatable`, which every `EventIdentifying` is).
    public init<Payload>(on caseInit: @escaping @Sendable (Payload) -> EventID, to target: StateID) {
        self.init(on: CasePath(caseInit), to: target)
    }

    /// Only take this transition when the predicate holds.
    public func when(_ predicate: @escaping Schema.Guard) -> Self {
        clone(mutating: \.node.`guard` <- predicate)
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
