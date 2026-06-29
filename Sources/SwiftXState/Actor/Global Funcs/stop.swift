/// Stops a child actor. Alias for `stopChild`, matching XState's deprecated `stop` export.
public func stop<Context: Sendable>(_ id: String) -> ActionRef<Context> {
    stopChild(id)
}

/// Stops a child actor whose id is resolved at runtime.
public func stop<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String
) -> ActionRef<Context> {
    stopChild(expression)
}

/// An action that stops the spawned/invoked child actor with the given id.
public func stopChild<Context: Sendable>(_ id: String) -> ActionRef<Context> {
    .stopChild(.fixed(id))
}

/// Stops a child actor whose id is resolved at runtime.
public func stopChild<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String
) -> ActionRef<Context> {
    .stopChild(.expression(expression))
}
