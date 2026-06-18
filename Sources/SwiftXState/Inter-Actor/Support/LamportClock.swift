import Foundation

/// A monotonically increasing logical clock (Lamport). Cheap and thread-safe, so the
/// inspection-forwarding closure (which runs on a hosted actor's queue thread) can stamp events
/// without hopping isolation. `witness(_:)` advances past a clock observed on an inbound message,
/// preserving happens-before across the async boundary.
public final class LamportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    @discardableResult
    public func tick() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }

    public func witness(_ incoming: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value = Swift.max(value, incoming) &+ 1
    }

    public var current: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
