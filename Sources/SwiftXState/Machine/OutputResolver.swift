/// Resolves output from a final state.
public typealias OutputResolver<Context: Sendable> = @Sendable (ActionArgs<Context>) -> SendableValue?
