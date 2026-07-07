/// The Context-agnostic runtime resources an effectful `ActorLogic` needs from its host actor while
/// handling an event — timers, children, parent/system wiring, emit. Because `Actor` provides
/// this and `ActorLogic.handle` takes the host as an **`isolated`** parameter, an effectful logic
/// (`MachineLogic`) runs its side-effect dispatch / `after` / `invoke` *inside the actor's isolation*
/// with no hops, exactly as `StateActor` does inline — but without the actor needing to know the
/// logic's `Context`. All the Context-specific work (the action switch, `makeChildActor`) lives in
/// the logic; the host only exposes these non-generic primitives.
public protocol MachineHosting: _Concurrency.Actor, ParentActorRepresentable, ActorSystemRef {
    var childRegistry: ChildRegistry { get }
    var hostClock: any Clock { get }
    func emit(_ event: EmittedEvent)
    func deliverToChild(id childId: String, event: any Eventable) async
    func enqueueToParent(_ event: any Eventable) async
    /// Synchronously enqueue an event to the parent on the ordered delivery chain (for reducer-style
    /// children like `fromTransition`, whose scope `sendToParent` is synchronous).
    func sendToParentOrdered(_ event: any Eventable)
    func scheduleSelfEvent(timerId: String, delay: Int, event: Event)
    func scheduleChildEvent(timerId: String, delay: Int, childId: String, event: Event)
    func cancelTimer(_ timerId: String)
    func registerChild(_ child: any ChildActorRepresentable)
    func unregisterChild(_ child: any ChildActorRepresentable)
    /// Subscribe to child `childId`'s emitted `eventType` (`"*"` = all) and relay `map(emitted)` back
    /// into this actor (XState v6 `enq.listen`). Torn down when this actor stops. Default: no-op —
    /// only the top-level machine actor tracks listener subscriptions.
    func listen(childId: String, eventType: String,
                map: @escaping @Sendable (EmittedEvent) -> (any Eventable)?) async
    /// Subscribe to child `childId`'s snapshot changes and relay `map(snapshot)` back into this actor
    /// (XState v6 `enq.subscribeTo`). Torn down when this actor stops. Default: no-op.
    func subscribeToChild(childId: String,
                          map: @escaping @Sendable (ChildActorSnapshot) -> (any Eventable)?) async
    /// The persisted snapshot to seed a child with during restore (nil in normal operation).
    func pendingChildSnapshot(_ id: String) -> PersistedChildSnapshot?

    // Inspection primitives, so an effectful logic can emit `.microstep` / `.action` events as it
    // runs. `emitInspection` keeps the `@autoclosure` guard (no Mirror-encode without an inspector).
    var inspectionActorRef: InspectionActorRef { get }
    var inspectionRootId: String { get }
    var recordsMicrosteps: Bool { get }
    func emitInspection(_ event: @autoclosure () -> InspectionEvent?)
}

public extension MachineHosting {
    func listen(childId: String, eventType: String,
                map: @escaping @Sendable (EmittedEvent) -> (any Eventable)?) async {}
    func subscribeToChild(childId: String,
                          map: @escaping @Sendable (ChildActorSnapshot) -> (any Eventable)?) async {}
}
