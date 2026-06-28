import CompositionalInit

// MARK: - Eventless structural transitions
//
// `Always`, `After`, and `OnDone` are the eventless siblings of `XTransition`: they live in an
// `XState { … }` body and fire on a condition (a guard, a delay, or child completion) rather than on
// an event. Each refines with the same chainable `.when(_:)` / `.action(_:)`.

/// An *eventless* transition — XState v6's `always`. Re-evaluated after every microstep; with
/// `.when(_:)` it's the v5-style "choice" (first passing guard wins).
///
/// ```swift
/// XState(.check) {
///     Always(to: .approved).when { $0.score >= 700 }
///     Always(to: .declined)
/// }
/// ```
public struct Always<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: Sendable, Cloneable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public var node: Schema.GuardedTransition

    public init(to target: StateID) {
        node = Schema.GuardedTransition(target: target)
    }

    /// Only take this transition when the predicate holds.
    public func when(_ predicate: @escaping Schema.Guard) -> Self {
        clone(mutating: \.node.`guard` <- predicate)
    }

    /// Apply a pure context transform as the transition is taken.
    public func action(_ transform: @escaping Schema.Action) -> Self {
        let handler: Schema.Handler = { args, _ in transform(args.context) }
        return clone(mutating: \.node.action <- handler)
    }

    /// Apply an effectful handler (`(args, enq) -> context`) as the transition is taken.
    public func action(_ handler: @escaping Schema.Handler) -> Self {
        clone(mutating: \.node.action <- handler)
    }
}

/// A *delayed* transition — XState v6's `after`. Fires `delay` after the state is entered (driven by
/// the actor's clock; use a `SimulatedClock` to test deterministically).
///
/// ```swift
/// XState(.loading) {
///     After(.seconds(5), to: .timedOut)
/// }
/// ```
public struct After<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: Sendable, Cloneable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public var delayMS: Int
    public var node: Schema.GuardedTransition

    public init(_ delay: Duration, to target: StateID) {
        self.delayMS = Self.milliseconds(delay)
        self.node = Schema.GuardedTransition(target: target)
    }

    public func when(_ predicate: @escaping Schema.Guard) -> Self {
        clone(mutating: \.node.`guard` <- predicate)
    }

    public func action(_ transform: @escaping Schema.Action) -> Self {
        let handler: Schema.Handler = { args, _ in transform(args.context) }
        return clone(mutating: \.node.action <- handler)
    }

    public func action(_ handler: @escaping Schema.Handler) -> Self {
        clone(mutating: \.node.action <- handler)
    }

    /// This declaration as a schema `AfterEntry`.
    public var entry: Schema.AfterEntry { Schema.AfterEntry(delayMS: delayMS, transition: node) }

    static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}

/// A transition taken when the enclosing compound/parallel state's children **complete** (reach a
/// `.final()` child, or — for parallel — all regions reach a final) — XState v6's `onDone`.
///
/// ```swift
/// XState(.wizard) {
///     OnDone(to: .summary)
///     XState(.step1) { … }.initial()
///     XState(.done) {}.final()
/// }
/// ```
public struct OnDone<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: Sendable, Cloneable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public var node: Schema.GuardedTransition

    public init(to target: StateID) {
        node = Schema.GuardedTransition(target: target)
    }

    public func when(_ predicate: @escaping Schema.Guard) -> Self {
        clone(mutating: \.node.`guard` <- predicate)
    }

    public func action(_ transform: @escaping Schema.Action) -> Self {
        let handler: Schema.Handler = { args, _ in transform(args.context) }
        return clone(mutating: \.node.action <- handler)
    }

    public func action(_ handler: @escaping Schema.Handler) -> Self {
        clone(mutating: \.node.action <- handler)
    }
}
