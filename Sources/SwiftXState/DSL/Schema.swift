import CompositionalInit

/// A composable machine component — the result-builder element, in the spirit of SwiftUI's `View`.
/// Each component knows how to *fold itself into* a `MachineSchema`. `XState`, `XTransition`-bearing
/// blocks, and `MachineSchema` itself all conform, so `@MachineBuilder` can reduce a declaration
/// block down to one schema.
public protocol SchemaReducible<Context, EventID, StateID>: MachineSchemable, Cloneable, Sendable {
    func folded(into schema: MachineSchema<Context, EventID, StateID>) -> MachineSchema<Context, EventID, StateID>
}

/// The concrete, folded description of a machine: its state nodes keyed by id, the declaration order,
/// and the initial state. Produced by `@MachineBuilder` from `XState` / `XTransition` components, and
/// resolved into a `ResolvedMachine` for the engine (Phase 3b).
public struct MachineSchema<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: SchemaReducible {
    /// A pure context transform — used for entry/exit, where there's no triggering event or effects.
    public typealias Action = @Sendable (consuming Context) -> Context
    /// A transition action — XState v6's `(args, enq) -> patch`. Returns the next context; effects
    /// (`raise`/`sendTo`/`emit`) are collected via `enq`.
    public typealias Handler = @Sendable (XTransitionArgs<Context, EventID>, Enqueue<Context, EventID>) -> Context
    /// A transition guard — a pure predicate over the (borrowed) context.
    public typealias Guard = @Sendable (borrowing Context) -> Bool

    public struct StateNode: Sendable, Identifiable {
        public let id: StateID
        /// Whether this node is the initial state among its siblings (its parent's `initial`, or the
        /// machine's `initial` at the root).
        public var isInitial: Bool
        /// `.parallel()` marker — XState v6's `type: 'parallel'`; its `children` become concurrently
        /// active regions instead of one-at-a-time substates.
        public var isParallel: Bool
        /// `.final()` marker — XState v6's `type: 'final'`; entering it completes the parent (firing
        /// the parent's `OnDone`).
        public var isFinal: Bool
        public var transitions: [TransitionNode]
        /// Eventless guarded transitions (`Always`) — re-evaluated after every microstep.
        public var always: [GuardedTransition]
        /// Delayed transitions (`After`).
        public var after: [AfterEntry]
        /// Transitions taken when this compound/parallel node's children complete (`OnDone`).
        public var onDone: [GuardedTransition]
        /// Child actors invoked while this state is active (`Invoke`).
        public var invokes: [InvokeNode]
        /// The output this (final) state produces on completion — XState v6's final-state `output`,
        /// read back by an enclosing `OnDone` / parent `onDone`.
        public var output: (@Sendable (Context) -> SendableValue?)?
        /// Entry/exit handlers — XState v6's `(args, enq) -> context` form (may patch context and
        /// enqueue effects; may not target). A pure `(consuming Context) -> Context` transform is
        /// wrapped into this shape by `XState.onEntry`/`onExit`.
        public var entry: Handler?
        public var exit: Handler?
        /// Child states in declaration order. Non-empty makes this a compound (or, with
        /// `isParallel`, a parallel) node.
        public var children: [StateNode]
        /// The initial child among `children` (compound only).
        public var initialChild: StateID?

        public init(
            id: StateID,
            isInitial: Bool = false,
            isParallel: Bool = false,
            isFinal: Bool = false,
            transitions: [TransitionNode] = [],
            always: [GuardedTransition] = [],
            after: [AfterEntry] = [],
            onDone: [GuardedTransition] = [],
            invokes: [InvokeNode] = [],
            output: (@Sendable (Context) -> SendableValue?)? = nil,
            entry: Handler? = nil,
            exit: Handler? = nil,
            children: [StateNode] = [],
            initialChild: StateID? = nil
        ) {
            self.id = id
            self.isInitial = isInitial
            self.isParallel = isParallel
            self.isFinal = isFinal
            self.transitions = transitions
            self.always = always
            self.after = after
            self.onDone = onDone
            self.invokes = invokes
            self.output = output
            self.entry = entry
            self.exit = exit
            self.children = children
            self.initialChild = initialChild
        }

        /// `.final` / `.parallel` / `.compound` (has children) / `.atomic` (leaf) — the engine node type.
        public var nodeType: StateNodeType {
            if isFinal { return .final }
            if isParallel { return .parallel }
            return children.isEmpty ? .atomic : .compound
        }
    }

    public struct TransitionNode: Sendable {
        /// The triggering event id. `nil` when the transition routes by a **case match** instead — a
        /// payload-carrying event referenced by its case path (registered under the wildcard key and
        /// gated by `caseMatch`).
        public let event: EventID?
        /// A case matcher (from `XTransition(on: Event.increment, …)`) — when set, the transition is
        /// registered under the wildcard event and taken only when the incoming event is this case.
        public var caseMatch: (@Sendable (EventID) -> Bool)?
        public let target: StateID
        public var `guard`: Guard?
        /// An **event-aware** guard — XState's `({ context, event }) => bool`. Gets the typed
        /// triggering event (`nil` for system/untyped events); AND-combined with `guard` / `caseMatch`.
        public var eventGuard: (@Sendable (Context, EventID?) -> Bool)?
        public var action: Handler?

        public init(
            event: EventID?,
            caseMatch: (@Sendable (EventID) -> Bool)? = nil,
            target: StateID,
            guard: Guard? = nil,
            eventGuard: (@Sendable (Context, EventID?) -> Bool)? = nil,
            action: Handler? = nil
        ) {
            self.event = event
            self.eventGuard = eventGuard
            self.caseMatch = caseMatch
            self.target = target
            self.guard = `guard`
            self.action = action
        }
    }

    /// An *eventless* transition — the lowered form of `Always` / `After` / `OnDone`, which fire on a
    /// condition (a guard, a delay, or child completion) rather than an event.
    public struct GuardedTransition: Sendable {
        public let target: StateID
        public var `guard`: Guard?
        public var action: Handler?
        /// Reads the completing child's / final state's `output` (XState v6's `onDone: ({ output })`).
        /// The raw `SendableValue?` comes from the engine's `DoneActorEvent` / `DoneStateEvent`; the
        /// typed `.action(reading:)` / `.onDone(to:_:)` overloads decode it before calling user code.
        public var outputAction: (@Sendable (SendableValue?, Context) -> Context)?
        /// Reads the failed child's `error` string (XState v6's `onError`), from `ErrorActorEvent`.
        public var errorAction: (@Sendable (String, Context) -> Context)?

        public init(
            target: StateID,
            guard: Guard? = nil,
            action: Handler? = nil,
            outputAction: (@Sendable (SendableValue?, Context) -> Context)? = nil,
            errorAction: (@Sendable (String, Context) -> Context)? = nil
        ) {
            self.target = target
            self.guard = `guard`
            self.action = action
            self.outputAction = outputAction
            self.errorAction = errorAction
        }
    }

    /// A delayed transition (`After`) — its `delayMS` becomes the engine's `after` key.
    public struct AfterEntry: Sendable {
        public var delayMS: Int
        public var transition: GuardedTransition
    }

    /// An invoked child actor (`Invoke`) — XState v6's `invoke`. Built from an `ActorSource` (a task
    /// or a child machine), optionally seeded with `input` from context, with `onDone` / `onError`
    /// transitions taken when the child completes or fails.
    public struct InvokeNode: Sendable {
        public var id: String
        public var src: ActorSource
        public var input: (@Sendable (Context) -> SendableValue?)?
        public var onDone: GuardedTransition?
        public var onError: GuardedTransition?
        /// Transition taken each time the child's snapshot changes (XState v6's `onSnapshot`); its
        /// presence turns on snapshot syncing for the child.
        public var onSnapshot: GuardedTransition?

        public init(
            id: String,
            src: ActorSource,
            input: (@Sendable (Context) -> SendableValue?)? = nil,
            onDone: GuardedTransition? = nil,
            onError: GuardedTransition? = nil,
            onSnapshot: GuardedTransition? = nil
        ) {
            self.id = id
            self.src = src
            self.input = input
            self.onDone = onDone
            self.onError = onError
            self.onSnapshot = onSnapshot
        }
    }

    public private(set) var states: [StateID: StateNode]
    public private(set) var order: [StateID]
    public private(set) var initialState: StateID?

    public init() {
        states = [:]
        order = []
        initialState = nil
    }

    init(states: [StateID: StateNode], order: [StateID], initialState: StateID?) {
        self.states = states
        self.order = order
        self.initialState = initialState
    }

    /// Add a state node — first declaration of an id wins, declaration order is recorded, and the
    /// first `.initial()` node fixes the initial state.
    public func adding(_ node: StateNode) -> Self {
        guard states[node.id] == nil else { return self }
        var newStates = states
        newStates[node.id] = node
        return Self(
            states: newStates,
            order: order + [node.id],
            initialState: initialState ?? (node.isInitial ? node.id : nil)
        )
    }

    public func folded(into schema: Self) -> Self {
        order.reduce(schema) { $0.adding(states[$1]!) }
    }
}
