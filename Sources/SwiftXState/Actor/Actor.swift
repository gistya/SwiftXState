import Foundation

/// A running instance of a `StateMachine` — the live process you `send` events to and read
/// `snapshot` from. Create one with `createActor(_:)`, then `start()` it. Thread-safe.
///
/// ```swift
/// let actor = createActor(toggle).start()
/// actor.send(Event("TOGGLE"))
/// actor.snapshot.matches("on")   // true
/// ```
///
/// **Temporary facade (generics refactor):** `Actor` now forwards to the generic `LogicActor`
/// engine running `MachineLogic<Context>`. This unifies the runtime on one engine (deleting the
/// duplicate effect dispatch) while preserving the entire public API. The inner engine is created at
/// `start`, so a `start(context:)` override is baked straight into the logic. A later step collapses
/// this facade and `Actor` becomes the engine directly.
public final class Actor<Context: Sendable>: ActorParentRef, ActorSystemRef, @unchecked Sendable {
    /// The machine this actor runs.
    public let machine: StateMachine<Context>
    /// This actor's session id (unique within its system).
    public let id: String
    private let options: ActorOptions
    private nonisolated let system: ActorSystem
    private weak var parent: (any ActorParentRef)?

    /// The inner engine. Created once at `start`; `@unchecked Sendable` is sound because it's written
    /// exactly once (start happens-before any use), mirroring "you start an actor, then use it".
    private var inner: LogicActor<MachineLogic<Context>>?

    /// The actor system this actor belongs to.
    public var actorSystem: ActorSystem { system }
    /// Alias for `id` — the session id used in inspection and cross-actor references.
    public var sessionId: String { id }
    /// The optional stable system id set via `ActorOptions.systemId`.
    public var systemId: String? { options.systemId }
    var isInspectable: Bool { options.inspectable }

    public init(
        _ machine: StateMachine<Context>,
        id: String? = nil,
        options: ActorOptions = ActorOptions(),
        parent: (any ActorParentRef)? = nil,
        system: ActorSystem? = nil
    ) {
        self.machine = machine
        self.id = id ?? machine.id
        self.options = options
        self.parent = parent
        self.system = system ?? parent?.actorSystem ?? ActorSystem()
        if parent == nil {
            self.system.setRootIdIfNeeded(self.id)
        }
    }

    public nonisolated func typed<Brand: StateID>(as _: Brand.Type = Brand.self) -> TypedActor<Context, Brand> {
        TypedActor(self)
    }

    /// Lifecycle status: `.active`, `.done`, `.error`, or `.stopped`. `.stopped` before `start`.
    public var status: SnapshotStatus {
        get async { await inner?.status ?? .stopped }
    }

    /// The current snapshot. Traps if the actor hasn't been started.
    public var snapshot: MachineSnapshot<Context> {
        get async {
            guard let inner else { fatalError("Actor has not been started. Call start() first.") }
            return await inner.snapshot
        }
    }

    public func getSnapshot() async -> MachineSnapshot<Context> { await snapshot }

    /// Returns a persisted representation of the current actor state.
    public func getPersistedSnapshot() async throws -> PersistedSnapshot where Context: Codable {
        guard let inner else { throw PersistenceError.actorNotStarted }
        return try await inner.getPersistedSnapshot()
    }

    /// Starts the actor and runs the initial transition. `input` feeds `contextFromInput`;
    /// `context` overrides the initial context. Returns `self` so you can chain.
    @discardableResult
    public func start(input: SendableValue? = nil, context: Context? = nil) async -> Self {
        let engine = LogicActor(
            MachineLogic(machine: machine, contextOverride: context),
            id: id, options: options, parent: parent, system: system
        )
        inner = engine
        await engine.start(input: input)
        return self
    }

    /// Starts the actor by **restoring** a previously persisted snapshot. `context` overrides the
    /// decoded context. Use for replay / resume.
    @discardableResult
    public func start(
        from persisted: PersistedSnapshot,
        context: Context? = nil
    ) async -> Self where Context: Codable {
        let engine = LogicActor(
            MachineLogic(machine: machine, contextOverride: context),
            id: id, options: options, parent: parent, system: system
        )
        inner = engine
        try? await engine.start(from: persisted)
        return self
    }

    /// Stops the actor and all invoked children.
    public func stop() async {
        await inner?.stop()
    }

    /// Sends an event to the actor.
    public func send(_ event: any Eventable) async {
        await inner?.send(event)
    }

    /// Listens for events emitted by `emit(…)` actions. Pass `"*"` for all emitted events.
    @discardableResult
    public func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        guard let inner else { return Subscription {} }
        return await inner.on(eventType, handler: handler)
    }

    /// Observe every snapshot. Fires immediately with the current snapshot, then on each transition.
    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (MachineSnapshot<Context>) -> Void) async -> Subscription {
        guard let inner else { return Subscription {} }
        return await inner.subscribe(handler)
    }

    func childActor(id: String) async -> (any ChildActorRef)? {
        await inner?.childActor(id: id)
    }

    // MARK: ActorParentRef (the facade is never itself a parent — children attach to `inner` — but
    // the conformance is preserved for API compatibility).

    public func enqueueFromChild(_ event: any Eventable) async {
        await inner?.enqueueFromChild(event)
    }

    public func inspectSpawnedChild(_ child: any ChildActorRef, machineId: String?) async {
        await inner?.inspectSpawnedChild(child, machineId: machineId)
    }
}
