/// A context update. Prefer the `assign` helper functions over constructing cases directly.
public enum AssignAction<Context: Sendable>: Sendable {
    /// Per-property assigners, each producing the new value from `(context, event)`.
    case properties([String: @Sendable (ActionArgs<Context>) -> SendableValue])
    /// A single mutating closure over the whole context.
    case function(@Sendable (inout Context, ActionArgs<Context>) -> Void)
}
