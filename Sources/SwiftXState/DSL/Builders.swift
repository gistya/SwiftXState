/// Result builder that reduces a block of `SchemaReducible` components (states, nested machines)
/// into one `MachineSchema` — the statechart analog of SwiftUI's `@ViewBuilder`.
@resultBuilder
public enum MachineBuilder<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
> {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public static func buildBlock(_ parts: any SchemaReducible<Context, EventID, StateID>...) -> Schema {
        parts.reduce(Schema()) { $1.folded(into: $0) }
    }

    public static func buildArray(_ parts: [any SchemaReducible<Context, EventID, StateID>]) -> Schema {
        parts.reduce(Schema()) { $1.folded(into: $0) }
    }

    public static func buildExpression(_ expr: any SchemaReducible<Context, EventID, StateID>) -> any SchemaReducible<Context, EventID, StateID> {
        expr
    }

    public static func buildOptional(_ part: Schema?) -> Schema {
        part ?? Schema()
    }

    public static func buildEither(first part: Schema) -> Schema { part }
    public static func buildEither(second part: Schema) -> Schema { part }
}

/// The accumulated contents of an `XState { … }` body: the state's own `transitions` plus its child
/// states (which make it compound/parallel) and which child is `initial`. The partial-result type of
/// `@StateBuilder`.
public struct StateBody<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
>: Sendable {
    public typealias Schema = MachineSchema<Context, EventID, StateID>

    public var transitions: [Schema.TransitionNode]
    public var children: [Schema.StateNode]
    public var initialChild: StateID?

    public init(
        transitions: [Schema.TransitionNode] = [],
        children: [Schema.StateNode] = [],
        initialChild: StateID? = nil
    ) {
        self.transitions = transitions
        self.children = children
        self.initialChild = initialChild
    }

    /// Concatenate two bodies; the first declared `initial` child wins.
    func merged(_ other: StateBody) -> StateBody {
        StateBody(
            transitions: transitions + other.transitions,
            children: children + other.children,
            initialChild: initialChild ?? other.initialChild
        )
    }
}

/// Result builder for the `XState { … }` trailing block — mixes `XTransition`s (the state's own
/// transitions) and `XState`s (its child states) into one `StateBody`.
@resultBuilder
public enum StateBuilder<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
> {
    public typealias Body = StateBody<Context, EventID, StateID>
    public typealias Tr = XTransition<Context, EventID, StateID>
    public typealias St = XState<Context, EventID, StateID>

    public static func buildExpression(_ transition: Tr) -> Body {
        Body(transitions: [transition.node])
    }

    public static func buildExpression(_ state: St) -> Body {
        Body(children: [state.node], initialChild: state.isInitial ? state.id : nil)
    }

    public static func buildBlock(_ parts: Body...) -> Body {
        parts.reduce(Body()) { $0.merged($1) }
    }

    public static func buildArray(_ parts: [Body]) -> Body {
        parts.reduce(Body()) { $0.merged($1) }
    }

    public static func buildOptional(_ part: Body?) -> Body { part ?? Body() }
    public static func buildEither(first part: Body) -> Body { part }
    public static func buildEither(second part: Body) -> Body { part }
}
