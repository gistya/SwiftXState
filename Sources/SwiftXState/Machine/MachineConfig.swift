/// Configuration for creating a state machine, mirroring XState's `createMachine` config.
public struct MachineConfig<Context: Sendable>: Sendable {
    /// The machine's id — the root state node's name, used for `#id` targets and in inspection.
    public var id: String?
    /// Key of the initial child state. Required for a compound machine with `states`.
    public var initial: String?
    /// The starting context value.
    public var context: Context?
    /// Builds initial context from actor input, mirroring XState's `context: ({ input }) => …`.
    public var contextFromInput: (@Sendable (SendableValue?) -> Context)?
    /// Child state nodes, keyed by name.
    public var states: [String: StateNodeConfig<Context>]
    /// Root-level event transitions — handled regardless of the current state.
    public var on: [String: TransitionInput<Context>]?
    /// Actions run when the machine starts (its root state is entered).
    public var entry: [ActionRef<Context>]?
    /// Actions run when the machine stops (its root state is exited).
    public var exit: [ActionRef<Context>]?
    /// Root node type — e.g. `.parallel` for a parallel machine.
    public var type: StateNodeType?
    /// Produces the machine's output when it reaches a top-level final state.
    public var output: OutputResolver<Context>?
    /// Optional human-readable description, carried into the exported definition JSON.
    public var description: String?

    public init(
        id: String? = nil,
        initial: String? = nil,
        context: Context? = nil,
        contextFromInput: (@Sendable (SendableValue?) -> Context)? = nil,
        states: [String: StateNodeConfig<Context>] = [:],
        on: [String: TransitionInput<Context>]? = nil,
        entry: [ActionRef<Context>]? = nil,
        exit: [ActionRef<Context>]? = nil,
        type: StateNodeType? = nil,
        output: OutputResolver<Context>? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.initial = initial
        self.context = context
        self.contextFromInput = contextFromInput
        self.states = states
        self.on = on
        self.entry = entry
        self.exit = exit
        self.type = type
        self.output = output
        self.description = description
    }
}
