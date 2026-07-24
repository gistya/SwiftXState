#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
import _Concurrency
#endif

/// Runs async child logic with an async `onCancel` handler bridged through `withTaskCancellationHandler`.
func runAsyncChildLogic<Output: Sendable>(
    cleanup: AsyncCancelCleanup,
    operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
    do {
        return try await withTaskCancellationHandler(operation: operation) {
            cleanup.schedule()
        }
    } catch is CancellationError {
        await cleanup.wait()
        throw CancellationError()
    }
}
