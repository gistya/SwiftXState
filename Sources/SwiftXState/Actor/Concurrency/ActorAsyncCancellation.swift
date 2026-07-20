#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
import _Concurrency
#endif

/// Cancellation helpers for `fromTask` / `fromTaskGroup` actor logic.
///
/// Use `checkCancellation()` or `isCancelled` inside long loops, and `withCancellationHandler`
/// for scoped cleanup around sub-operations (wraps `withTaskCancellationHandler`).
public enum ActorAsyncCancellation {
    public static var isCancelled: Bool { Task.isCancelled }

    public static func checkCancellation() throws {
        try Task.checkCancellation()
    }

    public static func withHandler<T: Sendable>(
        onCancel: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let cleanup = AsyncCancelCleanup(onCancel: onCancel)
        return try await runAsyncChildLogic(cleanup: cleanup, operation: operation)
    }
}
