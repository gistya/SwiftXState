import properties

/// A single transition declaration: on `event`, go `to` a target state — refined with the chainable
/// `.when(_:)` guard and `.action(_:)` context transform.
///
/// ```swift
/// XTransition(on: .stop, to: .red)
///     .when { ctx in ctx.cyclesOk }
///     .action { ctx in ctx.incrementingCycles() }
/// ```
public struct XTransition<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: Sendable, Clonable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public var node: Schema.TransitionNode

    init(node: Schema.TransitionNode) {
        self.node = node
    }

    public init(on event: EventID, to target: StateID) {
        node = Schema.TransitionNode(event: event, target: target, guard: nil, action: nil)
    }

    /// Only take this transition when the predicate holds.
    public func when(_ predicate: @escaping Schema.Guard) -> Self {
        var copy = self
        copy.node.`guard` = predicate
        return copy
    }

    /// Apply a pure context transform as the transition is taken (no effects).
    public func action(_ transform: @escaping Schema.Action) -> Self {
        var copy = self
        copy.node.action = { args, _ in transform(args.context) }
        return copy
    }

    /// Apply an effectful handler as the transition is taken — XState v6's `(args, enq) -> context`.
    /// Return the next context; `raise` / `sendTo` / `emit` through `enq`.
    public func action(_ handler: @escaping Schema.Handler) -> Self {
        var copy = self
        copy.node.action = handler
        return copy
    }
}
