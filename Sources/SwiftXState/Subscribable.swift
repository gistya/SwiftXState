import Foundation

/// A stream that can be subscribed to, mirroring XState's `Subscribable` (RxJS-compatible).
public protocol Subscribable<Element>: Sendable {
    associatedtype Element: Sendable & Equatable

    func subscribe(
        next: @escaping @Sendable (Element) -> Void,
        onError: (@Sendable (String) -> Void)?,
        onComplete: (@Sendable () -> Void)?
    ) -> Subscription
}

/// Type-erased subscribable for use in observable actor logic.
public struct AnySubscribable<T: Sendable & Equatable>: Sendable {
    private let _subscribe: @Sendable (
        @escaping @Sendable (T) -> Void,
        (@Sendable (String) -> Void)?,
        (@Sendable () -> Void)?
    ) -> Subscription

    public init<S: Subscribable>(_ subscribable: S) where S.Element == T {
        _subscribe = { next, onError, onComplete in
            subscribable.subscribe(next: next, onError: onError, onComplete: onComplete)
        }
    }

    public init(
        _ subscribe: @escaping @Sendable (
            @escaping @Sendable (T) -> Void,
            (@Sendable (String) -> Void)?,
            (@Sendable () -> Void)?
        ) -> Subscription
    ) {
        _subscribe = subscribe
    }

    public func subscribe(
        next: @escaping @Sendable (T) -> Void,
        onError: (@Sendable (String) -> Void)? = nil,
        onComplete: (@Sendable () -> Void)? = nil
    ) -> Subscription {
        _subscribe(next, onError, onComplete)
    }
}

/// Emits a finite sequence of values asynchronously, then completes.
public struct SequenceSubscribable<T: Sendable & Equatable>: Subscribable {
    public typealias Element = T

    private let values: [T]
    private let intervalMs: Int

    public init(values: [T], intervalMs: Int = 0) {
        self.values = values
        self.intervalMs = intervalMs
    }

    public func subscribe(
        next: @escaping @Sendable (T) -> Void,
        onError: (@Sendable (String) -> Void)?,
        onComplete: (@Sendable () -> Void)?
    ) -> Subscription {
        let task = Task {
            do {
                for value in values {
                    try Task.checkCancellation()
                    if intervalMs > 0 {
                        try await Task.sleep(for: .milliseconds(intervalMs))
                    }
                    next(value)
                }
                onComplete?()
            } catch is CancellationError {
                return
            } catch {
                onError?(String(describing: error))
            }
        }

        return Subscription {
            task.cancel()
        }
    }
}