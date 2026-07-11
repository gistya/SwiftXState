import Synchronization

/// Transitional manual locking operations for code whose critical sections must
/// temporarily release the lock. New code should prefer `withLock` directly.
public extension Mutex where Value == Bool {
    borrowing func lock() {
        while !withLock({ isLocked in
            guard !isLocked else { return false }
            isLocked = true
            return true
        }) {}
    }

    borrowing func unlock() {
        withLock { $0 = false }
    }
}
