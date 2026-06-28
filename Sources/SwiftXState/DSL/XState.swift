import CompositionalInit

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
    public var transitions: [Schema.TransitionNode]
    public var entry: Schema.Action?
    public var exit: Schema.Action?
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
        self.transitions = body.transitions
        self.entry = nil
        self.exit = nil
        self.children = body.children
        self.initialChild = body.initialChild
    }

    /// Mark this state the initial one among its siblings (the machine's initial at the root).
    public func initial(_ value: Bool = true) -> Self {
        clone(mutating: \.isInitial <- value)
    }

    /// Mark this a parallel state — XState v6's `type: 'parallel'`. Its child states become
    /// concurrently-active regions (each entering its own `.initial()` child).
    public func parallel(_ value: Bool = true) -> Self {
        clone(mutating: \.isParallel <- value)
    }

    /// Run a context transform when this state is entered.
    public func onEntry(_ body: @escaping Schema.Action) -> Self {
        clone(mutating: \.entry <- body)
    }

    /// Run a context transform when this state is exited.
    public func onExit(_ body: @escaping Schema.Action) -> Self {
        clone(mutating: \.exit <- body)
    }

    /// This declaration as a folded `StateNode` (recursively carrying its children).
    public var node: Schema.StateNode {
        Schema.StateNode(
            id: id,
            isInitial: isInitial,
            isParallel: isParallel,
            transitions: transitions,
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
