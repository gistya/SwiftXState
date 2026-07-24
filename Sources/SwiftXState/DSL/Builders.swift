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
    public var always: [Schema.GuardedTransition]
    public var after: [Schema.AfterEntry]
    public var onDone: [Schema.GuardedTransition]
    public var invokes: [Schema.InvokeNode]

    public init(
        transitions: [Schema.TransitionNode] = [],
        children: [Schema.StateNode] = [],
        initialChild: StateID? = nil,
        always: [Schema.GuardedTransition] = [],
        after: [Schema.AfterEntry] = [],
        onDone: [Schema.GuardedTransition] = [],
        invokes: [Schema.InvokeNode] = []
    ) {
        self.transitions = transitions
        self.children = children
        self.initialChild = initialChild
        self.always = always
        self.after = after
        self.onDone = onDone
        self.invokes = invokes
    }

    /// Concatenate two bodies; the first declared `initial` child wins.
    func merged(_ other: StateBody) -> StateBody {
        StateBody(
            transitions: transitions + other.transitions,
            children: children + other.children,
            initialChild: initialChild ?? other.initialChild,
            always: always + other.always,
            after: after + other.after,
            onDone: onDone + other.onDone,
            invokes: invokes + other.invokes
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
    public typealias Always = XAlways<Context, EventID, StateID>
    public typealias After = XAfter<Context, EventID, StateID>
    public typealias OnDone = XOnDone<Context, EventID, StateID>
    public typealias Invoke = XInvoke<Context, EventID, StateID>
    public typealias State = XState<Context, EventID, StateID>
    public typealias Transition = XTransition<Context, EventID, StateID>

    public static func buildExpression(_ transition: Transition) -> Body {
        Body(transitions: [transition.node])
    }

    public static func buildExpression(_ state: State) -> Body {
        Body(children: [state.node], initialChild: state.isInitial ? state.id : nil)
    }

    public static func buildExpression(_ always: Always) -> Body {
        Body(always: [always.node])
    }

    public static func buildExpression(_ after: After) -> Body {
        Body(after: [after.entry])
    }

    public static func buildExpression(_ onDone: OnDone) -> Body {
        Body(onDone: [onDone.node])
    }

    public static func buildExpression(_ invoke: Invoke) -> Body {
        Body(invokes: [invoke.node])
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
