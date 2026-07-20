#if hasFeature(Embedded)

// MARK: - Single-threaded Mutex stand-in for Embedded Swift
//
// Embedded Swift ships `Synchronization.Atomic` but not `Synchronization.Mutex`, so this supplies a
// source-compatible replacement with the same `borrowing withLock` shape. Every call site compiles
// unchanged.
//
// ⚠️ SOUNDNESS CONTRACT — READ BEFORE REUSING
//
// This provides **no mutual exclusion whatsoever**. It is sound only because an Embedded build of
// SwiftXState is assumed to run on a single thread of execution, where mutual exclusion is free and
// a lock is a no-op by construction.
//
// That assumption holds for bare-metal and cooperative-scheduler targets, which is the overwhelming
// majority of Embedded Swift deployments. It does **not** hold on an RTOS with preemptive tasks
// sharing one address space. On such a target this type will silently corrupt state rather than
// fail loudly, because the `@unchecked Sendable` below is a promise the compiler cannot verify.
//
// If SwiftXState ever targets a preemptive multi-threaded embedded environment, this must be
// replaced with a real lock built on `Atomic` (which Embedded does provide) — a test-and-set spin
// lock over `Atomic<Bool>` is the usual answer. Do not simply widen the `#if`.

/// A drop-in stand-in for `Synchronization.Mutex` on Embedded Swift, where that type is unavailable.
///
/// Provides no actual mutual exclusion — see the soundness contract in this file's header. The API
/// mirrors the standard library's so that call sites are identical across platforms.
public struct Mutex<Value>: @unchecked Sendable {
    private let storage: _MutexStorage<Value>

    /// Wraps `initialValue`. No lock is acquired; there is nothing to acquire.
    public init(_ initialValue: Value) {
        storage = _MutexStorage(initialValue)
    }

    /// Calls `body` with mutable access to the protected value.
    ///
    /// On a single-threaded target this is simply a scoped mutation — the "lock" is a no-op.
    public borrowing func withLock<Result>(
        _ body: (inout Value) throws -> Result
    ) rethrows -> Result {
        try body(&storage.storedValue)
    }
}

/// Class box giving the `borrowing` `withLock` a mutable slot to write through. A `final class` is
/// used because Embedded Swift supports classes and ARC; only `weak`/`unowned` are prohibited.
private final class _MutexStorage<Value>: @unchecked Sendable {
    var storedValue: Value
    init(_ storedValue: Value) { self.storedValue = storedValue }
}

#endif
