import Foundation
@testable import SwiftXState

/// A thread-safe, single-resolution box used to bridge a callback (snapshot
/// observer, action side effect, timer) into an `async` `await`. The first
/// `resolve(_:)` wins; later calls and the timeout are no-ops. This lets tests
/// await a *deterministic completion signal* instead of sleeping for a fixed
/// duration and hoping the work finished (which races under parallel load).
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var resolvedValue: T?
    private var isResolved = false

    func resolve(_ value: T) {
        lock.lock()
        if isResolved {
            lock.unlock()
            return
        }
        isResolved = true
        resolvedValue = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func get() async -> T {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isResolved, let value = resolvedValue {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// A one-shot completion signal a test can `await`. Fired from an action side
/// effect (e.g. an `.inline` action) and awaited deterministically, replacing
/// `try? await Task.sleep(...)` polling of a mutable flag.
final class TestSignal: @unchecked Sendable {
    private let oneShot = OneShot<Bool>()

    /// Marks the signal as fired, waking any current or future `wait()`.
    func fire() {
        oneShot.resolve(true)
    }

    /// Awaits the signal. Returns `true` if fired, `false` if the timeout
    /// elapsed first (so a hung machine fails the assertion instead of the suite).
    @discardableResult
    func wait(timeout: Duration = .seconds(5)) async -> Bool {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            oneShot.resolve(false)
        }
        defer { timeoutTask.cancel() }
        return await oneShot.get()
    }
}

extension Actor {
    /// Awaits the first snapshot satisfying `predicate`, subscribing to the
    /// actor's snapshot stream so it resolves the instant the transition lands —
    /// no fixed delay. Returns the matching snapshot, or `nil` on timeout.
    ///
    /// `subscribe` delivers the current snapshot synchronously on registration,
    /// so an already-satisfied predicate resolves immediately.
    @discardableResult
    func waitForSnapshot(
        timeout: Duration = .seconds(5),
        where predicate: @escaping (MachineSnapshot<Context>) -> Bool
    ) async -> MachineSnapshot<Context>? {
        let oneShot = OneShot<MachineSnapshot<Context>?>()
        let subscription = subscribe { snapshot in
            if predicate(snapshot) {
                oneShot.resolve(snapshot)
            }
        }
        defer { subscription.cancel() }

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            oneShot.resolve(nil)
        }
        defer { timeoutTask.cancel() }

        return await oneShot.get()
    }
}
