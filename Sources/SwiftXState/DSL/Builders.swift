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

/// Result builder for the `XState { … }` trailing block — collects `XTransition`s.
@resultBuilder
public enum TransitionBuilder<
    Context: Sendable,
    EventID: EventIdentifying,
    StateID: StateIdentifying
> {
    public typealias T = XTransition<Context, EventID, StateID>

    // The partial-result type is `[T]` throughout: `buildExpression` lifts one transition to a
    // 1-element array, `buildBlock` flattens the per-statement arrays.
    public static func buildExpression(_ expr: T) -> [T] { [expr] }
    public static func buildBlock(_ components: [T]...) -> [T] { components.flatMap { $0 } }
    public static func buildArray(_ components: [[T]]) -> [T] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [T]?) -> [T] { component ?? [] }
    public static func buildEither(first component: [T]) -> [T] { component }
    public static func buildEither(second component: [T]) -> [T] { component }
}
