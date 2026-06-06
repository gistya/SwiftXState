import Foundation

/// Forwards the triggering event to a child actor, mirroring XState's `forwardTo`.
public func forwardTo<Context: Sendable>(_ childId: String) -> ActionRef<Context> {
    .forwardTo(.fixed(childId))
}

/// Forwards the triggering event to a child whose id is resolved at runtime.
public func forwardTo<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String
) -> ActionRef<Context> {
    .forwardTo(.expression(expression))
}