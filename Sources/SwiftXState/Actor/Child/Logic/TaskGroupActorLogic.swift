/// Task group logic for structured concurrent child work.
public struct TaskGroupActorLogic<Output: Sendable & Equatable>: Sendable {
    public let run: @Sendable (TaskGroupScope) async throws -> [Output]
    public let onCancel: @Sendable (TaskGroupScope) async -> Void

    public init(
        run: @escaping @Sendable (TaskGroupScope) async throws -> [Output],
        onCancel: (@Sendable (TaskGroupScope) async -> Void)? = nil
    ) {
        self.run = run
        self.onCancel = onCancel ?? { _ in }
    }
}

/// Type-erased task group actor logic.
public struct TaskGroupActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?
    ) -> any ChildActor

    public init<Output: Sendable & Equatable>(_ logic: TaskGroupActorLogic<Output>) {
        _spawn = { id, input, parent, systemId in
            TaskGroupChildRef(id: id, systemId: systemId, input: input, parent: parent, logic: logic)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        systemId: String?
    ) -> any ChildActor {
        _spawn(id, input, parent, systemId)
    }
}

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
                try Task.checkCancellation()
                group.addTask {
                    try await operation()
                }
            }
            var results: [Output] = []
            for try await result in group {
                try Task.checkCancellation()
                results.append(result)
            }
            return results
        }
    }
}
