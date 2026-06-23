/// Type-erased machine actor logic for child state machines.
public struct MachineActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?,
        ActorOptions,
        Bool,
        PersistedChildSnapshot?
    ) -> any ChildActorRef

    /// Uses the child machine's `context` or `contextFromInput` to build initial context.
    public init<ChildContext: Sendable>(_ machine: StateMachine<ChildContext>) {
        _spawn = { id, input, parent, systemId, options, syncSnapshot, persistedChild in
            let resolvedContext = resolveInitialContext(machine: machine, input: input)
            let persistedRestore = machinePersistedRestore(
                from: persistedChild,
                childId: id,
                machineId: machine.id
            )
            return MachineChildRef(
                actor: Actor(
                    machine,
                    id: id,
                    options: options,
                    parent: parent
                ),
                systemId: systemId,
                parent: parent,
                context: resolvedContext,
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore
            )
        }
    }

    /// Uses the child machine's `context` or `contextFromInput` to build initial context.
    /// Child snapshots can be persisted and restored when `ChildContext` is `Codable`.
    public init<ChildContext: Codable & Sendable>(_ machine: StateMachine<ChildContext>) {
        _spawn = { id, input, parent, systemId, options, syncSnapshot, persistedChild in
            let actor = Actor(
                machine,
                id: id,
                options: options,
                parent: parent
            )
            let resolvedContext = resolveInitialContext(machine: machine, input: input)
            let persistedRestore = machinePersistedRestore(
                from: persistedChild,
                childId: id,
                machineId: machine.id
            )
            return MachineChildRef(
                actor: actor,
                systemId: systemId,
                parent: parent,
                context: resolvedContext,
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore,
                onRestore: { persisted in await actor.start(from: persisted) }
            )
        }
    }

    public init<ChildContext: Sendable>(
        _ machine: StateMachine<ChildContext>,
        context: @escaping @Sendable (SendableValue?) -> ChildContext
    ) {
        _spawn = { id, input, parent, systemId, options, syncSnapshot, persistedChild in
            let persistedRestore = machinePersistedRestore(
                from: persistedChild,
                childId: id,
                machineId: machine.id
            )
            return MachineChildRef(
                actor: Actor(
                    machine,
                    id: id,
                    options: options,
                    parent: parent
                ),
                systemId: systemId,
                parent: parent,
                context: context(input),
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore
            )
        }
    }

    public init<ChildContext: Codable & Sendable>(
        _ machine: StateMachine<ChildContext>,
        context: @escaping @Sendable (SendableValue?) -> ChildContext
    ) {
        _spawn = { id, input, parent, systemId, options, syncSnapshot, persistedChild in
            let actor = Actor(
                machine,
                id: id,
                options: options,
                parent: parent
            )
            let persistedRestore = machinePersistedRestore(
                from: persistedChild,
                childId: id,
                machineId: machine.id
            )
            return MachineChildRef(
                actor: actor,
                systemId: systemId,
                parent: parent,
                context: context(input),
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore,
                onRestore: { persisted in await actor.start(from: persisted) }
            )
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        options: ActorOptions,
        syncSnapshot: Bool,
        persistedChild: PersistedChildSnapshot? = nil
    ) -> any ChildActorRef {
        _spawn(id, input, parent, options.systemId, options, syncSnapshot, persistedChild)
    }
}

private func machinePersistedRestore(
    from persistedChild: PersistedChildSnapshot?,
    childId: String,
    machineId: String
) -> PersistedSnapshot? {
    guard let persistedChild else { return nil }
    if case let .machine(snapshot) = persistedChild {
        if snapshot.machineId != machineId {
            let error = PersistenceError.childMachineMismatch(
                childId: childId,
                expected: snapshot.machineId,
                actual: machineId
            )
            fatalError("\(error)")
        }
        return snapshot
    }
    return nil
}
