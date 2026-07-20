#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
import _Concurrency
#endif

//


/// Scope for running multiple async operations via `TaskGroup`.
public struct TaskGroupScope: Sendable {
    public let input: SendableValue?
    public let sendToParent: @Sendable (any Eventable) -> Void
    public let emit: @Sendable (EmittedEvent) -> Void

    public init(
        input: SendableValue?,
        sendToParent: @escaping @Sendable (any Eventable) -> Void,
        emit: @escaping @Sendable (EmittedEvent) -> Void
    ) {
        self.input = input
        self.sendToParent = sendToParent
        self.emit = emit
    }

    /// Runs operations concurrently and collects results in completion order.
    /// Respects task cancellation between operations and while collecting results.
    public func runGroup<Output: Sendable & Equatable>(
        _ operations: [@Sendable () async throws -> Output]
    ) async throws -> [Output] {
        try await withThrowingTaskGroup(of: Output.self) { group in
            for operation in operations {
                if Task.isCancelled { throw CancellationError() }
                group.addTask {
                    try await operation()
                }
            }
            var results: [Output] = []
            for try await result in group {
                if Task.isCancelled { throw CancellationError() }
                results.append(result)
            }
            return results
        }
    }
}
