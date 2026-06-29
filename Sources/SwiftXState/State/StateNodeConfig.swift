/// Configuration for a single state node.
public struct StateNodeConfig<Context: Sendable>: Sendable {
    /// Explicit id for this node, enabling `#id` absolute targets (defaults to the dotted path).
    public var id: String?
    /// Key of the initial child state (for a compound node).
    public var initial: String?
    /// The node type. Defaults to `.atomic` (leaf) or `.compound` (has `states`) if unset.
    public var type: StateNodeType?
    /// Nested child states, keyed by name.
    public var states: [String: StateNodeConfig<Context>]?
    /// Event transitions handled while this state is active.
    public var on: [String: TransitionInput<Context>]?
    /// Transitions taken when all child regions of this compound/parallel state complete.
    public var onDone: TransitionInput<Context>?
    /// Eventless ("always") transitions — re-evaluated after every microstep while active.
    public var always: [TransitionConfig<Context>]?
    /// Delayed transitions — keys are delay in milliseconds or a named delay reference.
    public var after: [String: TransitionInput<Context>]?
    /// Actors invoked while this state is active (`fromTask`, `fromCallback`, child machines, …).
    public var invoke: [InvokeConfig<Context>]?
    /// Actions run when this state is entered.
    public var entry: [ActionRef<Context>]?
    /// Actions run when this state is exited.
    public var exit: [ActionRef<Context>]?
    /// Tags exposed on the snapshot while this state is active (`snapshot.hasTag(_:)`).
    public var tags: [String]?
    /// Arbitrary metadata attached to this node (`snapshot.getMeta()`), exported to the definition.
    public var meta: [String: SendableValue]?
    /// Produces output when this state is a final state that completes.
    public var output: OutputResolver<Context>?
    /// Optional human-readable description, carried into the exported definition JSON.
    public var description: String?
    /// For a `.history` node: whether it restores shallow or deep history.
    public var history: HistoryType?
    /// Default target when a history state has no stored history (e.g. `target: "bar"`).
    public var target: String?

    public init(
        id: String? = nil,
        initial: String? = nil,
        type: StateNodeType? = nil,
        states: [String: StateNodeConfig<Context>]? = nil,
        on: [String: TransitionInput<Context>]? = nil,
        onDone: TransitionInput<Context>? = nil,
        always: [TransitionConfig<Context>]? = nil,
        after: [String: TransitionInput<Context>]? = nil,
        invoke: [InvokeConfig<Context>]? = nil,
        entry: [ActionRef<Context>]? = nil,
        exit: [ActionRef<Context>]? = nil,
        tags: [String]? = nil,
        meta: [String: SendableValue]? = nil,
        output: OutputResolver<Context>? = nil,
        description: String? = nil,
        history: HistoryType? = nil,
        target: String? = nil
    ) {
        self.id = id
        self.initial = initial
        self.type = type
        self.states = states
        self.on = on
        self.onDone = onDone
        self.always = always
        self.after = after
        self.invoke = invoke
        self.entry = entry
        self.exit = exit
        self.tags = tags
        self.meta = meta
        self.output = output
        self.description = description
        self.history = history
        self.target = target
    }
}
