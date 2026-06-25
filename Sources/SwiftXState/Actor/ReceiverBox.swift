import Foundation

/// A lock-guarded list of event receivers for a *runnable* logic (the `scope.receive` handlers of a
/// callback/task/observable child). Lock-boxed rather than actor-isolated so a background `run` can
/// register a receiver synchronously, while the actor delivers events on its own isolation — both
/// without a racing hop. Mirrors `CallbackChildRef`'s receiver list.
final class ReceiverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable (any Eventable) -> Void] = []

    func add(_ handler: @escaping @Sendable (any Eventable) -> Void) {
        lock.lock(); handlers.append(handler); lock.unlock()
    }

    func current() -> [@Sendable (any Eventable) -> Void] {
        lock.lock(); defer { lock.unlock() }
        return handlers
    }

    func removeAll() {
        lock.lock(); handlers.removeAll(); lock.unlock()
    }
}
