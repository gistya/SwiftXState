#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
// Without this, the Actor protocol is invisible and `isolated` parameters fail to type-check.
import _Concurrency
#endif

#if canImport(Darwin)
import Dispatch

/// An off-main **serial executor** backing a non-`useMainExecutor` ``Actor``.
///
/// Backing the actor directly with `DispatchSerialQueue.asUnownedSerialExecutor()` was observed to
/// *not* serialize the actor's isolated methods: ThreadSanitizer reported real data races, and
/// child-completion events were dropped because two `drain()`s ran concurrently and one bailed on the
/// `isProcessing` guard. Routing each job through the queue with an explicit, textbook `enqueue` —
/// `queue.async { job.runSynchronously(...) }` — restores true serial execution with a GCD
/// happens-before edge that TSan understands. (The exact cause inside libdispatch's built-in
/// `SerialExecutor` conformance is unconfirmed; the empirical difference is not.)
final class ActorSerialExecutor: SerialExecutor {
    private let queue: DispatchSerialQueue

    init(id: String) {
        // Per-actor label so queues are distinguishable in Instruments / crash logs / thread names.
        self.queue = DispatchSerialQueue(label: "SwiftXState.Actor.\(id)")
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        // Capture `self` strongly (via `asUnownedSerialExecutor()` inside the block) so the executor
        // outlives the queued job — the canonical SE-0392 shape.
        queue.async { [self] in
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Validates dynamic isolation assertions (`assumeIsolated` / `assertIsolated`) against *our*
    /// queue — restoring the check the `DispatchSerialQueue` backing used to provide. This fires only
    /// on the isolation-assertion path, never on the scheduling/hop path, so it does not reintroduce
    /// the serialization bug (verified under TSan).
    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
#endif
