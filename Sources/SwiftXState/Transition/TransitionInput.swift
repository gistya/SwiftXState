/// Transition input — supports XState's string shorthand, single config, or array.
public enum TransitionInput<Context: Sendable>: Sendable {
    /// Bare target shorthand, e.g. `"active"` — equivalent to `.to("active")`.
    case target(String)
    /// One fully-specified transition (target + guard + actions).
    case single(TransitionConfig<Context>)
    /// An ordered list of candidate transitions; the first whose guard passes is taken.
    case multiple([TransitionConfig<Context>]) // swiftlint:disable:this line_length

    /// Convenience for a target-only transition: `on: ["GO": .to("active")]`.
    public static func to(_ target: String) -> TransitionInput<Context> {
        .target(target)
    }
}
