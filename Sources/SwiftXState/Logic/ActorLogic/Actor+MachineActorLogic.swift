import Foundation

public extension Actor where L: MachineActorLogic {
    /// Create an actor for a state machine — `Actor(machine)`, the form `createActor(_:)` builds on.
    init(
        _ machine: ResolvedMachine<L.MachineContext>,
        id: String? = nil,
        options: ActorOptions = ActorOptions(),
        parent: (any ActorParentRef)? = nil,
        system: ActorSystem? = nil
    ) {
        self.init(
            L(machine: machine, contextOverride: nil),
            id: id ?? machine.id,
            options: options,
            parent: parent,
            system: system
        )
    }

    /// The machine this actor runs.
    var machine: ResolvedMachine<L.MachineContext> {
        get async { logic.machine }
    }

    /// `getSnapshot()` parity with the old `Actor` — the current machine snapshot.
    func getSnapshot() async -> L.Snapshot { snapshot }

    /// Starts the actor, optionally overriding the initial `context`. The override is baked into the
    /// logic before the initial transition (the engine reads `MachineLogic.contextOverride`).
    @discardableResult
    func start(input: SendableValue? = nil, context: L.MachineContext?) async -> Self {
        logic = L(machine: logic.machine, contextOverride: context)
        return await start(input: input)
    }

}

public extension Actor {
    /// Re-brands this actor with a compile-time state family (`TypedActor`). Constrained to the
    /// concrete `MachineLogic` so `self` is exactly the `Actor<MachineLogic<Context>>` `TypedActor` wraps.
    nonisolated func typed<Context, Brand: StateID>(as _: Brand.Type = Brand.self) -> TypedActor<Context, Brand>
    where L == MachineLogic<Context> {
        TypedActor(self)
    }
}

public extension Actor where L: MachineActorLogic & PersistableLogic {
    /// Restores a persisted snapshot, optionally overriding the decoded `context`. Non-throwing to
    /// match the previous `Actor.start(from:context:)`; a decode failure leaves the actor unstarted.
    @discardableResult
    func start(from persisted: PersistedSnapshot, context: L.MachineContext? = nil) async -> Self {
        logic = L(machine: logic.machine, contextOverride: context)
        _ = try? await restore(from: persisted)
        return self
    }
}
