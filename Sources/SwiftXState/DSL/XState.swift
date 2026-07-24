/// A single state declaration in the DSL. Its `@StateBuilder` body mixes **transitions** out of the
/// state and **child states** (making it compound) — XState's recursive node shape. Refined with the
/// chainable `.initial()` / `.parallel()` / `.onEntry` / `.onExit`.
///
/// ```swift
/// // atomic
/// XState(.green) { XTransition(on: .caution, to: .yellow) }.initial()
///
/// // compound: own transition + child states
/// XState(.crossing) {
///     XTransition(on: .powerOutage, to: .blinking)
///     XState(.walk) { XTransition(on: .timer, to: .wait) }.initial()
///     XState(.wait) { XTransition(on: .timer, to: .stop) }
///     XState(.stop) {}
/// }
///
/// // parallel: each child is a concurrently-active region
/// XState(.editing) {
///     XState(.bold)      { XState(.off){}.initial(); XState(.on){} }
///     XState(.underline) { XState(.off){}.initial(); XState(.on){} }
/// }.parallel()
/// ```
public struct XState<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: SchemaReducible, Identifiable, Cloneable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public let id: StateID
    public var isInitial: Bool
    public var isParallel: Bool
    public var isFinal: Bool
    public var transitions: [Schema.TransitionNode]
    public var always: [Schema.GuardedTransition]
    public var after: [Schema.AfterEntry]
    public var onDone: [Schema.GuardedTransition]
    public var invokes: [Schema.InvokeNode]
    public var output: (@Sendable (Context) -> SendableValue?)?
    public var entry: Schema.Handler?
    public var exit: Schema.Handler?
    public var children: [Schema.StateNode]
    public var initialChild: StateID?

    public init(
        _ id: StateID,
        @StateBuilder<Context, EventID, StateID> body: () -> StateBody<Context, EventID, StateID> = { StateBody() }
    ) {
        let body = body()
        self.id = id
        self.isInitial = false
        self.isParallel = false
        self.isFinal = false
        self.transitions = body.transitions
        self.always = body.always
        self.after = body.after
        self.onDone = body.onDone
        self.invokes = body.invokes
        self.output = nil
        self.entry = nil
        self.exit = nil
        self.children = body.children
        self.initialChild = body.initialChild
    }
    
    /// Mark this state the initial one among its siblings (the machine's initial at the root).
    public func initial(_ value: Bool = true) -> Self {
        var new = self
        new.isInitial = value
        return new
    }

    /// Mark this a parallel state — XState v6's `type: 'parallel'`. Its child states become
    /// concurrently-active regions (each entering its own `.initial()` child).
    public func parallel(_ value: Bool = true) -> Self {
        var new = self
        new.isParallel = value
        return new
    }

    /// Mark this a final state — XState v6's `type: 'final'`. Entering it completes the parent,
    /// firing the parent's `OnDone`.
    public func final(_ value: Bool = true) -> Self {
        var new = self
        new.isFinal = value
        return new
    }

    /// Produce a typed `output` from context when this (final) state is reached — XState v6's
    /// final-state `output`, read back by an enclosing `OnDone` / parent `onDone`.
    public func output<Output: Sendable & Equatable>(
        _ make: @escaping @Sendable (Context) -> Output
    ) -> Self {
        let resolver: @Sendable (Context) -> SendableValue? = { context in SendableValue(make(context)) }
        var new = self
        new.output = resolver
        return new
    }

    /// Run a pure context transform when this state is entered.
    public func onEntry(_ body: @escaping Schema.Action) -> Self {
        let handler: Schema.Handler = { args, _ in body(args.context) }
        var new = self
        new.entry = handler
        return new
    }

    /// Run an effectful entry handler — XState v6's `(args, enq) -> context`; patch context and
    /// `raise` / `sendTo` / `emit` through `enq`. (`args.event` is the event that triggered entry.)
    public func onEntry(_ handler: @escaping Schema.Handler) -> Self {
        var new = self
        new.entry = handler
        return new
    }

    /// Run a pure context transform when this state is exited.
    public func onExit(_ body: @escaping Schema.Action) -> Self {
        let handler: Schema.Handler = { args, _ in body(args.context) }
        var new = self
        new.exit = handler
        return new
    }

    /// Run an effectful exit handler — XState v6's `(args, enq) -> context`.
    public func onExit(_ handler: @escaping Schema.Handler) -> Self {
        var new = self
        new.exit = handler
        return new
    }

    /// This declaration as a folded `StateNode` (recursively carrying its children).
    public var node: Schema.StateNode {
        Schema.StateNode(
            id: id,
            isInitial: isInitial,
            isParallel: isParallel,
            isFinal: isFinal,
            transitions: transitions,
            always: always,
            after: after,
            onDone: onDone,
            invokes: invokes,
            output: output,
            entry: entry,
            exit: exit,
            children: children,
            initialChild: initialChild
        )
    }

    public func folded(into schema: Schema) -> Schema {
        schema.adding(node)
    }
}

public extension XState where StateID: CaseIterable {
    /// A v6 **choice state**: compute the target from context — `XState(.decide).choice { $0.isVip ? .vip : .standard }`.
    /// The engine has no dynamic target, so this expands to guarded `Always` candidates over
    /// `StateID.allCases` (one per case, guarded by `resolve(ctx) == case`); exactly the resolved
    /// target is taken on entry. Must resolve to a target.
    func choice(_ resolve: @escaping @Sendable (Context) -> StateID) -> Self {
        let candidates: [Schema.GuardedTransition] = StateID.allCases.map { target in
            Schema.GuardedTransition(target: target, guard: { ctx in resolve(ctx) == target })
        }
        return clone(mutating: \.always <- (always + candidates))
    }
}
