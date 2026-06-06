import Foundation

/// Identifies a scheduled delayed action to cancel.
public enum CancelId<Context: Sendable>: Sendable {
    case fixed(String)
    case expression(@Sendable (ActionArgs<Context>) -> String)
}

func resolveCancelId<Context: Sendable>(
    _ cancelId: CancelId<Context>,
    args: ActionArgs<Context>
) -> String {
    switch cancelId {
    case let .fixed(id):
        return id
    case let .expression(expression):
        return expression(args)
    }
}

/// Cancels a delayed `raise` (or other scheduled timer) by id.
public func cancel<Context: Sendable>(_ id: String) -> ActionRef<Context> {
    .cancel(CancelId<Context>.fixed(id))
}

/// Cancels a delayed action whose id is resolved at runtime.
public func cancel<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String
) -> ActionRef<Context> {
    .cancel(CancelId<Context>.expression(expression))
}