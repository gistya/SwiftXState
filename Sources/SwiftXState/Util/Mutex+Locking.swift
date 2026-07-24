import Synchronization

/// Transitional manual locking operations for code whose critical sections must
/// temporarily release the lock. New code should prefer `withLock` directly.
#if hasFeature(Embedded)
public extension Mutex where Value == Bool {
    /// Single-threaded Embedded build: mutual exclusion is free, so this only tracks the flag.
    ///
    /// The spin loop used on other platforms must NOT be used here. With one thread of execution
    /// there is nobody to release the flag, so re-entering `lock()` while already locked would spin
    /// forever instead of merely contending. The assertion converts that hang into a diagnosable
    /// failure in debug builds; on a real `Mutex` the same code path would deadlock.
    borrowing func lock() {
        withLock { isLocked in
            assert(!isLocked, "re-entrant lock() — on a real Mutex this deadlocks; on Embedded it hangs")
            isLocked = true
        }
    }

    borrowing func unlock() {
        withLock { $0 = false }
    }
}
#else
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
#endif
