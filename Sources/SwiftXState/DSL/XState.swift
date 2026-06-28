import CompositionalInit

/// A single state declaration in the DSL: an id, the transitions out of it, and optional entry/exit
/// context transforms. Built with the `@TransitionBuilder` trailing block, refined with the
/// chainable `.initial()` / `.onEntry` / `.onExit`.
///
/// ```swift
/// XState(.green) {
///     XTransition(on: .caution, to: .yellow)
/// }
/// .initial()
/// ```
public struct XState<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: SchemaReducible, Identifiable, Cloneable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public let id: StateID
    public var isInitial: Bool
    public var transitions: [Schema.TransitionNode]
    public var entry: Schema.Action?
    public var exit: Schema.Action?

    public init(
        _ id: StateID,
        @TransitionBuilder<Context, EventID, StateID> transitions: () -> [XTransition<Context, EventID, StateID>] = { [] }
    ) {
        self.id = id
        self.isInitial = false
        self.transitions = transitions().map(\.node)
        self.entry = nil
        self.exit = nil
    }

    /// Mark this state the machine's initial state.
    public func initial(_ value: Bool = true) -> Self {
        clone(mutating: \.isInitial <- value)
    }

    /// Run a context transform when this state is entered.
    public func onEntry(_ body: @escaping Schema.Action) -> Self {
        clone(mutating: \.entry <- body)
    }

    /// Run a context transform when this state is exited.
    public func onExit(_ body: @escaping Schema.Action) -> Self {
        clone(mutating: \.exit <- body)
    }

    public func folded(into schema: Schema) -> Schema {
        schema.adding(.init(id: id, isInitial: isInitial, transitions: transitions, entry: entry, exit: exit))
    }
}
