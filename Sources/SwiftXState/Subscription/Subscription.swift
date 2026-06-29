/// A handle returned by `Actor.subscribe(_:)`. Call `cancel()` to stop receiving snapshots.
public struct Subscription: Sendable {
    private let unsubscribe: @Sendable () -> Void

    init(unsubscribe: @escaping @Sendable () -> Void) {
        self.unsubscribe = unsubscribe
    }

    /// Stop receiving snapshot updates.
    public func cancel() {
        unsubscribe()
    }
}
