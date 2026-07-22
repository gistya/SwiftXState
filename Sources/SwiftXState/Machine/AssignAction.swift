/// A context update. Prefer the `assign` helper functions over constructing cases directly.
public enum AssignAction<Context: Sendable>: Sendable {
    #if !hasFeature(Embedded)
    /// Per-property assigners, each producing the new value from `(context, event)`.
    case properties([String: @Sendable (ActionArgs<Context>) -> SendableValue])
    #endif
    /// A single mutating closure over the whole context.
    case function(@Sendable (inout Context, ActionArgs<Context>) -> Void)
}
