/// Type-erased machine actor logic for child state machines. Spawns the child as a
/// `LogicChildActor<MachineLogic<ChildContext>>` — one generic engine, no bespoke `MachineChildRef`.
/// The inner `LogicActor` delivers the child's Done/Error and (for `syncSnapshot`) per-snapshot
/// events to the parent itself; here we only wire start-vs-restore and persistence.
public struct MachineActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?,
        ActorOptions,
        Bool,
        PersistedChildSnapshot?
    ) -> any ChildActor

    /// Uses the child machine's `context` or `contextFromInput` to build initial context.
    public init<ChildContext: Sendable>(_ machine: StateMachine<ChildContext>) {
        _spawn = { id, input, parent, systemId, options, syncSnapshot, _ in
            spawnMachineChild(
                machine: machine,
                context: resolveInitialContext(machine: machine, input: input),
                id: id, systemId: systemId, parent: parent, options: options, syncSnapshot: syncSnapshot
            )
        }
    }

    /// Uses the child machine's `context` or `contextFromInput` to build initial context.
    /// Child snapshots can be persisted and restored when `ChildContext` is `Codable`.
    public init<ChildContext: Codable & Sendable>(_ machine: StateMachine<ChildContext>) {
        _spawn = { id, input, parent, systemId, options, syncSnapshot, persistedChild in
            spawnCodableMachineChild(
                machine: machine,
                context: resolveInitialContext(machine: machine, input: input),
                id: id, systemId: systemId, parent: parent, options: options,
                syncSnapshot: syncSnapshot, persistedChild: persistedChild
            )
        }
    }

    public init<ChildContext: Sendable>(
        _ machine: StateMachine<ChildContext>,
        context: @escaping @Sendable (SendableValue?) -> ChildContext
    ) {
        _spawn = { id, input, parent, systemId, options, syncSnapshot, _ in
            spawnMachineChild(
                machine: machine,
                context: context(input),
                id: id, systemId: systemId, parent: parent, options: options, syncSnapshot: syncSnapshot
            )
        }
    }

    public init<ChildContext: Codable & Sendable>(
        _ machine: StateMachine<ChildContext>,
        context: @escaping @Sendable (SendableValue?) -> ChildContext
    ) {
        _spawn = { id, input, parent, systemId, options, syncSnapshot, persistedChild in
            spawnCodableMachineChild(
                machine: machine,
                context: context(input),
                id: id, systemId: systemId, parent: parent, options: options,
                syncSnapshot: syncSnapshot, persistedChild: persistedChild
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
    ) -> any ChildActor {
        _spawn(id, input, parent, options.systemId, options, syncSnapshot, persistedChild)
    }
}

/// Non-Codable machine child: starts fresh, not persistable.
private func spawnMachineChild<ChildContext: Sendable>(
    machine: StateMachine<ChildContext>,
    context: ChildContext,
    id: String,
    systemId: String?,
    parent: any ActorParentRef,
    options: ActorOptions,
    syncSnapshot: Bool
) -> any ChildActor {
    let engine = LogicActor(
        MachineLogic(machine: machine, contextOverride: context),
        id: id, options: options, parent: parent, system: parent.actorSystem, syncSnapshot: syncSnapshot
    )
    return LogicChildActor(
        actor: engine, id: id, systemId: systemId, inspectable: options.inspectable,
        machineId: machine.id, definitionJSON: try? machine.definitionJSON(),
        start: { inner in await inner.start(input: nil) },
        persist: { _, _, _ in nil }
    )
}

/// Codable machine child: persists as `.machine(...)`, restores via `start(from:)`.
private func spawnCodableMachineChild<ChildContext: Codable & Sendable>(
    machine: StateMachine<ChildContext>,
    context: ChildContext,
    id: String,
    systemId: String?,
    parent: any ActorParentRef,
    options: ActorOptions,
    syncSnapshot: Bool,
    persistedChild: PersistedChildSnapshot?
) -> any ChildActor {
    let persistedRestore = machinePersistedRestore(from: persistedChild, childId: id, machineId: machine.id)
    // On restore the persisted context must win, so don't bake in a fresh contextOverride (which
    // `restoredSnapshot` would otherwise apply over the decoded context).
    let engine = LogicActor(
        MachineLogic(machine: machine, contextOverride: persistedRestore == nil ? context : nil),
        id: id, options: options, parent: parent, system: parent.actorSystem, syncSnapshot: syncSnapshot
    )
    return LogicChildActor(
        actor: engine, id: id, systemId: systemId, inspectable: options.inspectable,
        machineId: machine.id, definitionJSON: try? machine.definitionJSON(),
        start: { inner in
            if let persistedRestore {
                try? await inner.start(from: persistedRestore)
            } else {
                await inner.start(input: nil)
            }
        },
        persist: { inner, _, _ in .machine(try await inner.getPersistedSnapshot()) }
    )
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
