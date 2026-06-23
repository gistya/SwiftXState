extension TaskGroupScope {
    public var isCancelled: Bool { ActorAsyncCancellation.isCancelled }

    public func checkCancellation() throws {
        try ActorAsyncCancellation.checkCancellation()
    }

    public func withCancellationHandler<T: Sendable>(
        onCancel: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await ActorAsyncCancellation.withHandler(onCancel: onCancel, operation: operation)
    }
}
