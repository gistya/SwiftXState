import Foundation

/// Identifies a child reactor by id or runtime expression.
public enum ChildTarget<Context: Sendable>: Sendable {
    case fixed(String)
    case expression(@Sendable (ActionArgs<Context>) -> String)
}

func resolveChildTarget<Context: Sendable>(
    _ target: ChildTarget<Context>,
    args: ActionArgs<Context>
) -> String {
    switch target {
    case let .fixed(id):
        return id
    case let .expression(expression):
        return expression(args)
    }
}
