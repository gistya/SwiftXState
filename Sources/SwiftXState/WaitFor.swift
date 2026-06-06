import Foundation

private final class WaitForState<Context: Sendable>: @unchecked Sendable {
    var finished = false
    var subscription: Subscription?
    var timeoutTask: Task<Void, Never>?
    var continuation: CheckedContinuation<MachineSnapshot<Context>, Error>?
    let lock = NSLock()

    func dispose() {
        subscription?.cancel()
        subscription = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func finish(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        body()
    }
}

/// Options for `waitFor`.
public struct WaitForOptions: Sendable {
    /// How long to wait before throwing, in milliseconds. `nil` means no timeout.
    public var timeout: Int?

    public init(timeout: Int? = nil) {
        self.timeout = timeout
    }
}

/// Errors thrown by `waitFor`.
public enum WaitForError: Error, Equatable, LocalizedError {
    case timeout(milliseconds: Int)
    case actorTerminated

    public var errorDescription: String? {
        switch self {
        case let .timeout(milliseconds):
            return "Timeout of \(milliseconds) ms exceeded"
        case .actorTerminated:
            return "Actor terminated without satisfying predicate"
        }
    }
}

/// Subscribes to an actor and waits until its snapshot satisfies a predicate.
///
/// Checks the current snapshot first. Throws if the predicate is not satisfied
/// before an optional timeout (default: no timeout) or if the actor stops.
public func waitFor<Context: Sendable>(
    _ actor: Actor<Context>,
    predicate: @escaping @Sendable (MachineSnapshot<Context>) -> Bool,
    options: WaitForOptions = WaitForOptions()
) async throws -> MachineSnapshot<Context> {
    if let timeout = options.timeout, timeout < 0 {
        #if DEBUG
        print("`timeout` passed to `waitFor` is negative and it will reject immediately.")
        #endif
        throw WaitForError.timeout(milliseconds: timeout)
    }

    try Task.checkCancellation()

    let initial = actor.snapshot
    if predicate(initial) {
        return initial
    }

    let state = WaitForState<Context>()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation

            func checkEmitted(_ snapshot: MachineSnapshot<Context>) {
                if predicate(snapshot) {
                    state.finish {
                        state.dispose()
                        continuation.resume(returning: snapshot)
                        state.continuation = nil
                    }
                } else if snapshot.status == .stopped {
                    state.finish {
                        state.dispose()
                        continuation.resume(throwing: WaitForError.actorTerminated)
                        state.continuation = nil
                    }
                }
            }

            state.subscription = actor.subscribe { snapshot in
                checkEmitted(snapshot)
            }

            if let timeout = options.timeout {
                state.timeoutTask = Task {
                    try? await Task.sleep(for: .milliseconds(timeout))
                    guard !Task.isCancelled else { return }
                    state.finish {
                        state.dispose()
                        continuation.resume(throwing: WaitForError.timeout(milliseconds: timeout))
                        state.continuation = nil
                    }
                }
            }
        }
    } onCancel: {
        state.finish {
            state.dispose()
            state.continuation?.resume(throwing: CancellationError())
            state.continuation = nil
        }
    }
}