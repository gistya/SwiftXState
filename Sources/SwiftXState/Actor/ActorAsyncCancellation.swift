import Foundation
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
import os
#else
import Synchronization
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

private final class CancelTaskState: Sendable {
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
    private let lock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    #else
    private let lock = Mutex<Task<Void, Never>?>(nil)
    #endif
    private let onCancel: @Sendable () async -> Void

    init(onCancel: @escaping @Sendable () async -> Void) {
        self.onCancel = onCancel
    }

    func schedule() {
        lock.withLock { task in
            if task == nil {
                task = Task { await onCancel() }
            }
        }
    }

    func currentTask() -> Task<Void, Never>? {
        lock.withLock { $0 }
    }
}

final class AsyncCancelCleanup: Sendable {
    private let taskState: CancelTaskState

    init(onCancel: @escaping @Sendable () async -> Void) {
        self.taskState = CancelTaskState(onCancel: onCancel)
    }

    func schedule() {
        taskState.schedule()
    }

    func wait() async {
        await taskState.currentTask()?.value
    }
}

/// How opaque invoke children (task, callback, taskGroup) behave when hydrating from a persisted snapshot.
public enum OpaqueInvokeRestorePolicy: String, Sendable, Codable, Equatable {
    /// Always spawn a fresh child (default). Pair with `onCancel` to clean up partial external work.
    case restart
    /// Skip auto-spawn on restore when the persisted opaque child was `.active` (in-flight).
    /// Use entry actions to reconcile external stores, then manually re-invoke or transition.
    case skipIfActive
    /// Skip auto-spawn whenever any opaque persisted child snapshot exists (active, done, or error).
    case skipIfPresent
}

func shouldSpawnOpaqueChild(
    persistedChild: PersistedChildSnapshot?,
    policy: OpaqueInvokeRestorePolicy
) -> Bool {
    guard let persistedChild, case let .opaque(snapshot) = persistedChild else {
        return true
    }

    switch policy {
    case .restart:
        return true
    case .skipIfActive:
        return snapshot.status != .active
    case .skipIfPresent:
        return false
    }
}

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

extension TaskActorScope {
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