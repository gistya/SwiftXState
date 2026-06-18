import Foundation

/// A thread-safe fan-out of ``ScopedInspectionEvent``. Mirrors the codebase's lock-based
/// `@unchecked Sendable` registries (see `Reactor.System`, `InspectionCollector`): emitting happens
/// on whatever thread produced the event, so it can't be actor-isolated.
public final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: @Sendable (ScopedInspectionEvent) -> Void] = [:]
    private var nextToken = 0

    public init() {}

    func emit(_ event: ScopedInspectionEvent) {
        lock.lock()
        let current = Array(sinks.values)
        lock.unlock()
        for sink in current { sink(event) }
    }

    @discardableResult
    func addSink(_ sink: @escaping @Sendable (ScopedInspectionEvent) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        sinks[token] = sink
        return token
    }

    func removeSink(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        sinks[token] = nil
    }

    /// Synchronously observe every event emitted after subscription — the handler fires on the
    /// producer's thread, so by the time a triggering `await` returns, the event is already in
    /// hand (handy for deterministic collection/tests). Returns a `Subscription`; `cancel()` to
    /// stop. For async iteration, prefer ``stream()``.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (ScopedInspectionEvent) -> Void) -> Subscription {
        let token = addSink(handler)
        return Subscription { [weak self] in self?.removeSink(token) }
    }

    /// A live stream of every event emitted after subscription. Cancelling the consuming task
    /// removes the sink.
    public func stream() -> AsyncStream<ScopedInspectionEvent> {
        AsyncStream { continuation in
            let token = addSink { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in self?.removeSink(token) }
        }
    }
}
