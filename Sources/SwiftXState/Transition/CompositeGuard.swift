/// A boolean combination of guards — build with `and(_:_:)`, `or(_:_:)`, `not(_:)`, or `.stateIn`.
public indirect enum CompositeGuard<Context: Sendable>: Sendable {
    /// All sub-guards must pass.
    case and([GuardRef<Context>])
    /// At least one sub-guard must pass.
    case or([GuardRef<Context>])
    /// The sub-guard must fail.
    case not(GuardRef<Context>)
    /// Passes when the machine is currently in the given state path (XState's `stateIn`).
    case stateIn(String)
}
