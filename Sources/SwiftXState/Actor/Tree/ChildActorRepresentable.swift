/// A running child actor managed by a parent state machine actor.
public protocol ChildActorRepresentable: ActorSystemRef, AnyObject, Sendable {
    var id: String { get }
    var status: SnapshotStatus { get }
    var errorMessage: String? { get }
    var machineId: String? { get }
    var definitionJSON: String? { get }
    /// Whether Inspector should receive events attributed to this child.
    var inspectable: Bool { get }
    func start() async
    func stop() async
    func send(_ event: any Eventable) async
    func on(_ eventType: String, handler: @escaping @Sendable (EmittedEvent) -> Void) async -> Subscription
    /// Subscribe to this child's snapshot changes (status / value), for `enq.subscribeTo`. Fires with
    /// the current snapshot immediately, then on each change. Default: no-op.
    func subscribe(_ handler: @escaping @Sendable (ChildActorSnapshot) -> Void) async -> Subscription

    /// This child's persisted form, or `nil` if it cannot be restored (task / callback children).
    ///
    /// Declared here rather than discovered by casting to a separate capability protocol. Embedded
    /// Swift permits `as?` to a *concrete* type but not to an existential (`as? any P`), so a
    /// defaulted requirement is both portable and more discoverable — the capability is visible on
    /// the protocol instead of found at runtime.
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot?
}

extension ChildActorRepresentable {
    /// Default: not persistable.
    public func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot? { nil }

    public var sessionId: String { id }
    public func subscribe(_ handler: @escaping @Sendable (ChildActorSnapshot) -> Void) async -> Subscription {
        Subscription {}
    }
    public var errorMessage: String? { nil }
    public var machineId: String? { nil }
    public var snapshotValue: String? { nil }
    public var inspectable: Bool { true }
}
