import Synchronization

/// Handle returned by `Clock.setTimeout`, used to cancel a scheduled callback.
///
/// An opaque token rather than a boxed value. It previously wrapped `any Sendable` and each clock
/// recovered its payload with a conditional cast; Embedded Swift permits neither existentials nor
/// dynamic casts, and the token is simpler regardless — each clock keeps its own id-to-timer table.
public struct TimeoutHandle: Sendable, Hashable {
    /// Unique within the issuing clock. Handles are not portable between clocks.
    public let id: UInt64

    @inlinable
    public init(id: UInt64) {
        self.id = id
    }
}

/// A clock responsible for scheduling and clearing delayed callbacks.
public protocol Clock: Sendable {
    func setTimeout(_ fn: @escaping @Sendable () -> Void, delay: Int) -> TimeoutHandle
    func clearTimeout(_ handle: TimeoutHandle)
}

#if canImport(Dispatch)
import Dispatch

/// Keeps scheduled work items addressable by token, so `TimeoutHandle` can stay a plain value.
private final class DispatchTimeoutStore: @unchecked Sendable {
    private let lock = Mutex(false)
    private var items: [UInt64: DispatchWorkItem] = [:]
    private var nextID: UInt64 = 0

    func insert(_ item: DispatchWorkItem) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        items[nextID] = item
        return nextID
    }

    func take(_ id: UInt64) -> DispatchWorkItem? {
        lock.lock()
        defer { lock.unlock() }
        return items.removeValue(forKey: id)
    }
}

/// Default clock using `DispatchQueue` (Apple platforms, Linux, Windows).
public struct DefaultClock: Clock {
    private let store = DispatchTimeoutStore()

    public init() {}

    public func setTimeout(_ fn: @escaping @Sendable () -> Void, delay: Int) -> TimeoutHandle {
        let store = self.store
        var id: UInt64 = 0
        let workItem = DispatchWorkItem {
            // Drop the bookkeeping entry once it fires, so a long-lived clock does not accumulate
            // completed work items.
            _ = store.take(id)
            fn()
        }
        id = store.insert(workItem)
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(delay),
            execute: workItem
        )
        return TimeoutHandle(id: id)
    }

    public func clearTimeout(_ handle: TimeoutHandle) {
        store.take(handle.id)?.cancel()
    }
}
#else
/// Default clock on platforms without Dispatch (e.g. WebAssembly / WASI).
///
/// These platforms provide no built-in timer source, so delayed (`after:`) transitions do **not**
/// fire under this clock. Apps that need delays should inject a host-backed `Clock` — for example
/// one driven by JavaScript's `setTimeout` via JavaScriptKit — through `ActorOptions.clock`.
public struct DefaultClock: Clock {
    public init() {}

    public func setTimeout(_ fn: @escaping @Sendable () -> Void, delay: Int) -> TimeoutHandle {
        TimeoutHandle(id: 0)
    }

    public func clearTimeout(_ handle: TimeoutHandle) {}
}
#endif

/// A manually controlled clock for deterministic tests.
public final class SimulatedClock: Clock, @unchecked Sendable {
    private struct SimulatedTimeout {
        var start: Int
        var timeout: Int
        var fn: @Sendable () -> Void
    }

    private var timeouts: [UInt64: SimulatedTimeout] = [:]
    private var currentTime: Int = 0
    private var nextId: UInt64 = 0
    private var flushing = false
    private var flushingInvalidated = false
    private let lock = Mutex(false)

    public init() {}

    public func now() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    public func setTimeout(_ fn: @escaping @Sendable () -> Void, delay: Int) -> TimeoutHandle {
        lock.lock()
        defer { lock.unlock() }
        flushingInvalidated = flushing
        let id = nextId
        nextId += 1
        timeouts[id] = SimulatedTimeout(start: currentTime, timeout: delay, fn: fn)
        return TimeoutHandle(id: id)
    }

    public func clearTimeout(_ handle: TimeoutHandle) {
        lock.lock()
        defer { lock.unlock() }
        flushingInvalidated = flushing
        timeouts.removeValue(forKey: handle.id)
    }

    public func set(_ time: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard currentTime <= time else {
            fatalError("Unable to travel back in time")
        }
        currentTime = time
        flushTimeoutsLocked()
    }

    public func increment(_ ms: Int) {
        lock.lock()
        defer { lock.unlock() }
        currentTime += ms
        flushTimeoutsLocked()
    }

    private func flushTimeoutsLocked() {
        if flushing {
            flushingInvalidated = true
            return
        }
        flushing = true
        defer { flushing = false }

        while true {
            if flushingInvalidated {
                flushingInvalidated = false
                break
            }

            let due = timeouts
                .filter { currentTime - $0.value.start >= $0.value.timeout }
                .sorted { lhs, rhs in
                    let endA = lhs.value.start + lhs.value.timeout
                    let endB = rhs.value.start + rhs.value.timeout
                    return endA > endB
                }

            guard let (id, timeout) = due.first else { break }

            timeouts.removeValue(forKey: id)
            lock.unlock()
            timeout.fn()
            lock.lock()
        }
    }
}


// MARK: - Erased clock

/// A `Clock` erased to plain function values.
///
/// `Clock` remains the protocol you conform to; this is how the engine *stores* one. A protocol
/// existential (`any Clock`) requires a runtime witness table, which Embedded Swift does not have,
/// whereas closures are ordinary values that specialize. The generic initializer is where the
/// specialization happens, so the concrete clock type is baked in at the call site.
public struct ClockHandle: Clock {
    private let _setTimeout: @Sendable (@escaping @Sendable () -> Void, Int) -> TimeoutHandle
    private let _clearTimeout: @Sendable (TimeoutHandle) -> Void

    /// Passing an already-erased handle is a no-op rather than another layer of closures. This
    /// overload is preferred over the generic one below by ordinary overload resolution, so
    /// forwarding a clock between actors does not accumulate indirection.
    public init(_ handle: ClockHandle) {
        self = handle
    }

    public init<C: Clock>(_ clock: C) {
        _setTimeout = { fn, delay in clock.setTimeout(fn, delay: delay) }
        _clearTimeout = { handle in clock.clearTimeout(handle) }
    }

    public func setTimeout(_ fn: @escaping @Sendable () -> Void, delay: Int) -> TimeoutHandle {
        _setTimeout(fn, delay)
    }

    public func clearTimeout(_ handle: TimeoutHandle) {
        _clearTimeout(handle)
    }
}
