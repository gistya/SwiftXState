import properties

/// A composable machine component — the result-builder element, in the spirit of SwiftUI's `View`.
/// Each component knows how to *fold itself into* a `MachineSchema`. `XState`, `XTransition`-bearing
/// blocks, and `MachineSchema` itself all conform, so `@MachineBuilder` can reduce a declaration
/// block down to one schema.
public protocol SchemaReducible<Context, EventID, StateID>: MachineSchemable, Clonable, Sendable {
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
    /// A pure context transform (entry/exit/transition action). The `enq` effect channel arrives in
    /// Phase 4; for now an action just maps context to context.
    public typealias Action = @Sendable (consuming Context) -> Context
    /// A transition guard — a pure predicate over the (borrowed) context.
    public typealias Guard = @Sendable (borrowing Context) -> Bool

    public struct StateNode: Sendable, Identifiable {
        public let id: StateID
        public var isInitial: Bool
        public var transitions: [TransitionNode]
        public var entry: Action?
        public var exit: Action?
    }

    public struct TransitionNode: Sendable {
        public let event: EventID
        public let target: StateID
        public var `guard`: Guard?
        public var action: Action?
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
