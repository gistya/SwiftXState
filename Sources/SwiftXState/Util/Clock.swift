import Foundation

/// Handle returned by `Clock.setTimeout`, used to cancel a scheduled callback.
public struct TimeoutHandle: Sendable {
    fileprivate let box: any Sendable

    fileprivate init(_ box: any Sendable) {
        self.box = box
    }
}

/// A clock responsible for scheduling and clearing delayed callbacks.
public protocol Clock: Sendable {
    func setTimeout(_ fn: @escaping @Sendable () -> Void, delay: Int) -> TimeoutHandle
    func clearTimeout(_ handle: TimeoutHandle)
}

#if canImport(Dispatch)
import Dispatch

private final class DispatchTimeout: @unchecked Sendable {
    let workItem: DispatchWorkItem

    init(_ workItem: DispatchWorkItem) {
        self.workItem = workItem
    }
}

/// Default clock using `DispatchQueue` (Apple platforms, Linux, Windows).
public struct DefaultClock: Clock {
    public init() {}

    public func setTimeout(_ fn: @escaping @Sendable () -> Void, delay: Int) -> TimeoutHandle {
        let workItem = DispatchWorkItem(block: fn)
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(delay),
            execute: workItem
        )
        return TimeoutHandle(DispatchTimeout(workItem))
    }

    public func clearTimeout(_ handle: TimeoutHandle) {
        (handle.box as? DispatchTimeout)?.workItem.cancel()
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
        TimeoutHandle(0 as Int)
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

    private var timeouts: [Int: SimulatedTimeout] = [:]
    private var currentTime: Int = 0
    private var nextId: Int = 0
    private var flushing = false
    private var flushingInvalidated = false
    private let lock = NSLock()

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
        return TimeoutHandle(id)
    }

    public func clearTimeout(_ handle: TimeoutHandle) {
        lock.lock()
        defer { lock.unlock() }
        flushingInvalidated = flushing
        guard let id = handle.box as? Int else { return }
        timeouts.removeValue(forKey: id)
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