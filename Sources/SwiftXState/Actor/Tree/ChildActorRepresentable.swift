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
}

extension ChildActorRepresentable {
    public var sessionId: String { id }
    public func subscribe(_ handler: @escaping @Sendable (ChildActorSnapshot) -> Void) async -> Subscription {
        Subscription {}
    }
    public var errorMessage: String? { nil }
    public var machineId: String? { nil }
    public var snapshotValue: String? { nil }
    public var inspectable: Bool { true }
}
