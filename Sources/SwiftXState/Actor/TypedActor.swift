/// A phantom-branded wrapper around `Actor` that returns `TypedSnapshot` values for the
/// selected state-id brand. The wrapper shares the underlying actor instance instead of
/// duplicating interpreter state.
public struct TypedActor<Context: Sendable, Brand: StateID>: Sendable {
    public let actor: Actor<MachineLogic<Context>>

    public init(_ actor: Actor<MachineLogic<Context>>) {
        self.actor = actor
    }

    /// The machine this actor runs.
    public var machine: StateMachine<Context> { get async { await actor.machine } }

    /// This actor's session id.
    public var id: String { actor.id }

    /// Alias for `id` used in inspection and cross-actor references.
    public var sessionId: String { actor.sessionId }

    /// The optional stable system id set via `ActorOptions.systemId`.
    public var systemId: String? { actor.systemId }

    /// The actor system this actor belongs to.
    public var actorSystem: ActorSystem { actor.actorSystem }

    /// Lifecycle status: `.active`, `.done`, `.error`, or `.stopped`.
    public var status: SnapshotStatus {
        get async { await actor.status }
    }

    /// The current typed snapshot of the actor.
    public var snapshot: TypedSnapshot<Context, Brand> {
        get async { await actor.snapshot.typed(as: Brand.self) }
    }

    /// Returns a persisted representation of the current actor state.
    public func getPersistedSnapshot() async throws -> PersistedSnapshot where Context: Codable {
        try await actor.getPersistedSnapshot()
    }

    @discardableResult
    public func start(context: Context? = nil) async -> TypedSnapshot<Context, Brand> {
        await actor.start(context: context)
        return await snapshot
    }

    /// Starts the actor by restoring a previously persisted snapshot.
    @discardableResult
    public func start(
        from persisted: PersistedSnapshot,
        context: Context? = nil
    ) async -> TypedSnapshot<Context, Brand> where Context: Codable {
        await actor.start(from: persisted, context: context)
        return await snapshot
    }

    /// Starts the actor and runs the initial transition.
    @discardableResult
    public func start(input: SendableValue? = nil, context: Context? = nil) async -> TypedSnapshot<Context, Brand> {
        await actor.start(input: input, context: context)
        return await snapshot
    }

    /// Stop this actor and any spawned children.
    public func stop() async {
        await actor.stop()
    }

    /// Send an event to the actor and return the resulting typed snapshot.
    @discardableResult
    public func send(_ event: any Eventable) async -> TypedSnapshot<Context, Brand> {
        await actor.send(event)
        return await snapshot
    }

    /// Subscribe to snapshot changes.
    public func subscribe(
        _ handler: @escaping @Sendable (TypedSnapshot<Context, Brand>) -> Void
    ) async -> Subscription {
        await actor.subscribe { snapshot in
            handler(snapshot.typed(as: Brand.self))
        }
    }

    /// Subscribe to emitted events by type.
    public func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        await actor.on(eventType, handler: handler)
    }
}
