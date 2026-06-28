import Foundation

/// A typed actor facade over a `StateMachine` declaration — the *running* counterpart of the typed
/// DSL. Where the engine's `Actor` speaks strings (`send(Event("GO"))`, `snapshot.value: StateValue`),
/// `MachineActor` speaks the machine's own id families: `send(.go)` takes an `EventID`, and the
/// snapshot reads back as a typed `Configuration<StateID>` — no `.event` / `configuration(from:)`
/// lowering at the call site.
///
/// It shares the underlying `Actor` instance rather than duplicating interpreter state; the `schema`
/// it carries is what projects the engine's `StateValue` back into the typed `Configuration`. Drop to
/// the public `actor` for the untyped escape hatch (raw `Eventable` sends, persistence, inspection).
///
/// ```swift
/// let light = createActor(TrafficLight())
/// await light.start()
/// await light.send(.go)
/// #expect(await light.matches(.green))
/// ```
public struct MachineActor<M: StateMachine>: Sendable {
    public typealias Context = M.Context
    public typealias EventID = M.EventID
    public typealias StateID = M.StateID

    /// The underlying engine actor — the untyped escape hatch (raw `Eventable` sends, persistence,
    /// inspection subscriptions, child spawning).
    public let actor: Actor<MachineLogic<Context>>

    /// The folded schema, kept solely to project the engine's `StateValue` into a typed
    /// `Configuration<StateID>`.
    public let schema: MachineSchema<Context, EventID, StateID>

    init(actor: Actor<MachineLogic<Context>>, schema: MachineSchema<Context, EventID, StateID>) {
        self.actor = actor
        self.schema = schema
    }

    // MARK: - Identity / lifecycle

    /// This actor's session id.
    public var id: String { actor.id }

    /// Alias for `id` used in inspection and cross-actor references.
    public var sessionId: String { actor.sessionId }

    /// Lifecycle status: `.active`, `.done`, `.error`, or `.stopped`.
    public var status: SnapshotStatus {
        get async { await actor.status }
    }

    /// Start the actor, optionally overriding the initial context. Returns the initial typed
    /// configuration.
    @discardableResult
    public func start(context: Context? = nil) async -> Configuration<StateID>? {
        await actor.start(context: context)
        return await configuration
    }

    /// Stop this actor and any spawned children.
    public func stop() async {
        await actor.stop()
    }

    // MARK: - Typed send

    /// Send a typed event — `actor.send(.go)`, no string / `.event` lowering at the call site.
    /// Returns the resulting typed configuration.
    @discardableResult
    public func send(_ id: EventID) async -> Configuration<StateID>? {
        await actor.send(id.event)
        return await configuration
    }

    // MARK: - Typed snapshot

    /// The current active position as a typed `Configuration<StateID>` — the typed analog of
    /// `snapshot.value`. `nil` only if the engine value names a state outside this schema.
    public var configuration: Configuration<StateID>? {
        get async { schema.configuration(from: await actor.snapshot.value) }
    }

    /// The current context.
    public var context: Context {
        get async { await actor.snapshot.context }
    }

    /// Whether the atomic state `id` is currently active.
    public func matches(_ id: StateID) async -> Bool {
        await configuration?.matches(id) ?? false
    }

    /// Subscribe to snapshot changes, projected to the typed `Configuration` + `Context`.
    public func subscribe(
        _ handler: @escaping @Sendable (Configuration<StateID>?, Context) -> Void
    ) async -> Subscription {
        let schema = schema
        return await actor.subscribe { snapshot in
            handler(schema.configuration(from: snapshot.value), snapshot.context)
        }
    }
}

// MARK: - Construction

public extension StateMachine {
    /// Build, resolve, and wrap this declaration into a typed `MachineActor` ready to `.start()` —
    /// the typed-DSL counterpart of `createActor(resolvedMachine)`.
    func actor(
        id: String? = nil,
        options: ActorOptions = ActorOptions()
    ) -> MachineActor<Self> {
        createActor(self, id: id, options: options)
    }
}

/// Create a typed `MachineActor` from a `StateMachine` declaration — the typed-DSL overload of
/// `createActor(_:)`, mirroring XState's `createActor(machine)`. Folds + resolves the schema once and
/// shares it with the wrapper for `StateValue → Configuration` projection.
public func createActor<M: StateMachine>(
    _ machine: M,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> MachineActor<M> {
    let schema = machine.buildSchema()
    let engine = createActor(schema.resolve(id: id), id: id, options: options, inspect: inspect)
    return MachineActor(actor: engine, schema: schema)
}
