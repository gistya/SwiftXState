import Foundation

private final class WaitForState<Context: Sendable>: @unchecked Sendable {
    var subscription: Subscription?
    var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var continuation: CheckedContinuation<MachineSnapshot<Context>, Error>?
    private var pending: Result<MachineSnapshot<Context>, Error>?
    private let lock = NSLock()

    /// Attaches the continuation. If a result already arrived (the subscription / timeout can fire
    /// before the continuation is installed, now that `subscribe` is async), resume immediately.
    func attach(_ continuation: CheckedContinuation<MachineSnapshot<Context>, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        if let pending {
            finished = true
            let sub = subscription, task = timeoutTask
            subscription = nil; timeoutTask = nil
            lock.unlock()
            sub?.cancel(); task?.cancel()
            continuation.resume(with: pending)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// Resolves the wait. Buffers the result if the continuation isn't installed yet.
    func resolve(_ result: Result<MachineSnapshot<Context>, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if let continuation {
            finished = true
            self.continuation = nil
            let sub = subscription, task = timeoutTask
            subscription = nil; timeoutTask = nil
            lock.unlock()
            sub?.cancel(); task?.cancel()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
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
public func waitFor<Context: Sendable>(
    _ actor: Actor<MachineLogic<Context>>,
    predicate: @escaping @Sendable (MachineSnapshot<Context>) -> Bool,
    options: WaitForOptions = WaitForOptions()
) async throws -> MachineSnapshot<Context> {
    try await actor.waitFor(predicate: predicate, options: options)
}


public extension Actor where L: MachineActorLogic {
    /// Subscribes to an actor and waits until its snapshot satisfies a predicate.
    ///
    /// Checks the current snapshot first. Throws if the predicate is not satisfied
    /// before an optional timeout (default: no timeout) or if the actor stops.
    func waitFor(
        predicate: @escaping @Sendable (MachineSnapshot<L.MachineContext>) -> Bool,
        options: WaitForOptions = WaitForOptions()
    ) async throws -> MachineSnapshot<L.MachineContext> {
        if let timeout = options.timeout, timeout < 0 {
            #if DEBUG
            print("`timeout` passed to `waitFor` is negative and it will reject immediately.")
            #endif
            throw WaitForError.timeout(milliseconds: timeout)
        }

        try Task.checkCancellation()

        let initial = snapshot
        if predicate(initial) {
            return initial
        }

        let state = WaitForState<L.MachineContext>()

        // Subscribe up front (now async). The immediate fire is a no-op because `predicate(initial)`
        // is already false above; any later snapshot routes through `state.resolve`, which buffers
        // until the continuation is installed.
        state.subscription = subscribe { snapshot in
            if predicate(snapshot) {
                state.resolve(.success(snapshot))
            } else if snapshot.status == .stopped {
                state.resolve(.failure(WaitForError.actorTerminated))
            }
        }

        if let timeout = options.timeout {
            state.timeoutTask = Task {
                try? await Task.sleep(for: .milliseconds(timeout))
                guard !Task.isCancelled else { return }
                state.resolve(.failure(WaitForError.timeout(milliseconds: timeout)))
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.attach(continuation)
            }
        } onCancel: {
            state.resolve(.failure(CancellationError()))
        }
    }
}
