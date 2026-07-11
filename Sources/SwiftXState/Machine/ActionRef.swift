/// A reference to an action. Build these with the helper functions (`assign`, `sendTo`, `raise`,
/// `log`, `spawnChild`, …) rather than constructing cases directly.
public enum ActionRef<Context: Sendable>: Sendable {
    /// A guard/action registered by name via `setup(actions:)`.
    case named(String)
    /// A named action with bound parameters (see `actionRef(_:params:)`).
    case parameterized(String, ParamsBox)
    /// Update context (`assign { … }`).
    case assign(AssignAction<Context>)
    /// An inline, unnamed action closure.
    case inline(@Sendable (ActionArgs<Context>) -> Void)
    /// Spawn a child actor.
    case spawn(SpawnRef<Context>)
    /// Stop a spawned/invoked child.
    case stopChild(ChildTarget<Context>)
    /// Forward the current event to a child.
    case forwardTo(ChildTarget<Context>)
    /// Send an event to another actor.
    case sendTo(SendToAction<Context>)
    /// Send an event to the parent actor.
    case sendToParent(Event)
    /// Raise an event back into this machine (processed in the same or a later step).
    case raise(RaiseAction<Context>)
    /// Cancel a previously-scheduled delayed `raise`/`sendTo` by id.
    case cancel(CancelId<Context>)
    /// Imperatively enqueue actions/guards (`enqueueActions { … }`).
    case enqueueActions(@Sendable (EnqueueActionsBuilder<Context>) -> Void)
    /// Emit a log line.
    case log(LogAction<Context>)
    /// Emit an event to external subscribers.
    case emit(EmitAction<Context>)
    /// Subscribe to a child actor's emitted events and relay a mapped event back into this machine
    /// (XState v6 `enq.listen`). The subscription is torn down when this actor stops.
    case listen(ListenAction<Context>)
    /// Subscribe to a child actor's snapshot changes and relay a mapped event back into this machine
    /// (XState v6 `enq.subscribeTo`). The subscription is torn down when this actor stops.
    case subscribeToChild(SubscribeChildAction<Context>)
    /// Subscribe to a reactive ``ReadableAtom``'s changes and relay a mapped event back into this
    /// machine (XState v6 `enq.subscribeTo(atom)`). The subscription is torn down when this actor stops.
    case subscribeToAtom(SubscribeAtomAction<Context>)
}

/// A `listen` effect: subscribe to child `childId`'s emitted events of type `eventType` (`"*"` = all)
/// and relay `map(emitted)` back into this machine. `nil` drops the emission.
public struct ListenAction<Context: Sendable>: Sendable {
    public let childId: String
    public let eventType: String
    public let map: @Sendable (EmittedEvent) -> (any Eventable)?
}

/// Build a `listen` effect (see `ListenAction`). Prefer `enq.listen(...)` in the typed DSL.
public func listen<Context: Sendable>(
    childId: String,
    eventType: String,
    map: @escaping @Sendable (EmittedEvent) -> (any Eventable)?
) -> ActionRef<Context> {
    .listen(ListenAction(childId: childId, eventType: eventType, map: map))
}

/// A `subscribeTo` effect: subscribe to child `childId`'s snapshot changes and relay `map(snapshot)`
/// back into this machine. `nil` drops the snapshot.
public struct SubscribeChildAction<Context: Sendable>: Sendable {
    public let childId: String
    public let map: @Sendable (ChildActorSnapshot) -> (any Eventable)?
}

/// Build a `subscribeTo` effect (see `SubscribeChildAction`). Prefer `enq.subscribeTo(...)`.
public func subscribeToChild<Context: Sendable>(
    childId: String,
    map: @escaping @Sendable (ChildActorSnapshot) -> (any Eventable)?
) -> ActionRef<Context> {
    .subscribeToChild(SubscribeChildAction(childId: childId, map: map))
}

/// A `subscribeTo(atom)` effect: subscribe to a reactive atom and relay each mapped value back into
/// this machine. The atom's value type is erased here into `subscribe`, which takes the actor's relay
/// (call it with the event to enqueue) and returns the ``Subscription`` to cancel on stop.
public struct SubscribeAtomAction<Context: Sendable>: Sendable {
    public let subscribe: @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Subscription
}

/// Build a `subscribeTo(atom)` effect (see `SubscribeAtomAction`). Prefer `enq.subscribeTo(atom) { … }`.
public func subscribeToAtom<Context: Sendable, V>(
    _ atom: any ReadableAtom<V>,
    map: @escaping @Sendable (V) -> (any Eventable)?
) -> ActionRef<Context> {
    .subscribeToAtom(SubscribeAtomAction { relay in
        atom.subscribe { value in
            if let event = map(value) { relay(event) }
        }
    })
}
