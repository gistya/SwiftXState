#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
import _Concurrency
#endif

import Synchronization

private final class WaitForState<Context: Sendable>: @unchecked Sendable {
    var subscription: Subscription?
    var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var continuation: CheckedContinuation<MachineSnapshot<Context>, Error>?
    private var pending: Result<MachineSnapshot<Context>, Error>?
    private let lock = Mutex(false)

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
public enum WaitForError: Error, Equatable {
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

        if Task.isCancelled { throw CancellationError() }

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

        // Embedded Swift has no `Task.sleep` — it provides no clock at all, since time is a host
        // concern there. The wait itself still works; only the *timeout* cannot be enforced, so a
        // `waitFor` that would have timed out instead waits until the predicate matches or the actor
        // stops. The assertion makes that visible during development rather than at 3am on a device.
        //
        // The proper fix is to route this through the `Clock` abstraction the engine already uses
        // for `after:` transitions, so the host supplies the timer. That is a larger change than
        // this migration, and is tracked as the remaining Embedded feature gap.
        if let timeout = options.timeout {
            #if hasFeature(Embedded)
            assertionFailure("waitFor(timeout:) cannot be enforced on Embedded Swift — no clock is available")
            _ = timeout
            #else
            state.timeoutTask = Task {
                try? await Task.sleep(for: .milliseconds(timeout))
                guard !Task.isCancelled else { return }
                state.resolve(.failure(WaitForError.timeout(milliseconds: timeout)))
            }
            #endif
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
