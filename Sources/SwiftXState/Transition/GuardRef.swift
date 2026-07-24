/// A reference to a guard. Build with `.inline { … }`, `.named("…")`, `guardRef(_:params:)`,
/// or the composite combinators `and` / `or` / `not`.
public indirect enum GuardRef<Context: Sendable>: Sendable {
    /// A guard registered by name via `setup(guards:)`.
    case named(String)
    /// A named guard with bound parameters.
    case parameterized(String, ParamsBox)
    /// An inline predicate over `(context, event)`.
    case inline(@Sendable (ActionArgs<Context>) -> Bool)
    /// A boolean combination of other guards.
    case composite(CompositeGuard<Context>)
}
