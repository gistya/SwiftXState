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
public struct XAlways<
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
public struct XAfter<
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
public struct XOnDone<
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

    /// Read the completed region's typed `output` as the done transition is taken — XState v6's
    /// `onDone: ({ output }) => …`. The final state's `output` is decoded to `Output`; if it's absent
    /// or a different type, the context passes through unchanged.
    public func action<Output: Sendable & Equatable>(
        reading _: Output.Type = Output.self,
        _ transform: @escaping @Sendable (Output, Context) -> Context
    ) -> Self {
        let outputAction: @Sendable (SendableValue?, Context) -> Context = { output, context in
            guard let value = output?.get(Output.self) else { return context }
            return transform(value, context)
        }
        return clone(mutating: \.node.outputAction <- outputAction)
    }
}

// MARK: - Invoke (child actors)

/// An invoked child actor — XState v6's `invoke`. The child runs while the enclosing state is
/// active; `.onDone(to:)` / `.onError(to:)` fire when it completes or fails, and `.input(_:)` seeds
/// it from the parent context.
///
/// ```swift
/// XState(.loading) {
///     Invoke(id: "load", run: { _ in try await fetch() })
///         .onDone(to: .loaded)
///         .onError(to: .failed)
/// }
///
/// // or a child machine:
/// XState(.playing) {
///     Invoke(id: "timer", machine: TimerMachine()).onDone(to: .done)
/// }
/// ```
public struct XInvoke<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: Sendable, Cloneable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public var node: Schema.InvokeNode

    /// Invoke an async task as the child — XState v6's `createAsyncLogic` / v5 `fromPromise`.
    public init<Output: Sendable & Equatable>(
        id: String,
        run: @escaping @Sendable (TaskActorScope) async throws -> Output
    ) {
        node = Schema.InvokeNode(id: id, src: fromTask(run))
    }

    /// Invoke another `StateMachine` declaration as the child actor.
    public init<M: StateMachine>(id: String, machine: M) {
        node = Schema.InvokeNode(id: id, src: fromMachine(machine.resolvedMachine(id: id)))
    }

    /// Invoke from an already-built `ActorSource` (the engine escape hatch — callbacks, stores, …).
    public init(id: String, source: ActorSource) {
        node = Schema.InvokeNode(id: id, src: source)
    }

    /// Seed the child's `input` from the parent context.
    public func input(_ make: @escaping @Sendable (Context) -> SendableValue?) -> Self {
        clone(mutating: \.node.input <- make)
    }

    /// Transition taken when the child completes successfully.
    public func onDone(to target: StateID) -> Self {
        clone(mutating: \.node.onDone <- Schema.GuardedTransition(target: target))
    }

    /// Transition taken when the child completes — reading the child's typed `output` into the
    /// parent context (XState v6's `onDone: ({ output }) => …`). Absent / mismatched output passes
    /// the context through unchanged.
    public func onDone<Output: Sendable & Equatable>(
        to target: StateID,
        reading _: Output.Type = Output.self,
        _ transform: @escaping @Sendable (Output, Context) -> Context
    ) -> Self {
        let outputAction: @Sendable (SendableValue?, Context) -> Context = { output, context in
            guard let value = output?.get(Output.self) else { return context }
            return transform(value, context)
        }
        return clone(mutating: \.node.onDone <- Schema.GuardedTransition(target: target, outputAction: outputAction))
    }

    /// Transition taken when the child errors.
    public func onError(to target: StateID) -> Self {
        clone(mutating: \.node.onError <- Schema.GuardedTransition(target: target))
    }

    /// Transition taken each time the child's snapshot changes — XState v6's `onSnapshot`. Enabling
    /// it turns on snapshot syncing for the child.
    public func onSnapshot(to target: StateID) -> Self {
        clone(mutating: \.node.onSnapshot <- Schema.GuardedTransition(target: target))
    }

    /// Transition taken when the child errors — reading the error string into the parent context
    /// (XState v6's `onError`).
    public func onError(
        to target: StateID,
        _ transform: @escaping @Sendable (String, Context) -> Context
    ) -> Self {
        clone(mutating: \.node.onError <- Schema.GuardedTransition(target: target, errorAction: transform))
    }
}
