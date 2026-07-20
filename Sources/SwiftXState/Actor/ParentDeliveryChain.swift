#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
import _Concurrency
#endif

import Synchronization

/// Serializes a child's deliveries to its parent. Each delivery awaits the previous one, so the
/// events a child sends keep their order — and, crucially, a `DoneActorEvent`/`ErrorActorEvent`
/// enqueued right after the child's work finishes lands *after* any event the work sent just before
/// returning. (Without this, the deliveries are detached tasks that race, so the parent can transition
/// on the done event before it ever processes the earlier `sendToParent`.)
final class ParentDeliveryChain: @unchecked Sendable {
    private let lock = Mutex(false)
    private var tail: Task<Void, Never>?

    func deliver(to parent: (any ParentActorRepresentable)?, _ event: any Eventable) {
        lock.lock()
        let previous = tail
        tail = Task { [weak parent] in
            await previous?.value
            await parent?.enqueueFromChild(event)
        }
        lock.unlock()
    }

    /// Waits until everything queued so far has been enqueued to the parent.
    func drain() async {
        let task = lock.withLock { _ in tail }
        await task?.value
    }
}
