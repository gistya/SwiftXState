import Foundation

/// Configuration for invoking a child actor when entering a state.
public struct InvokeConfig<Context: Sendable>: Sendable {
    public var id: String
    public var src: ActorSource
    public var systemId: String?
    public var input: (@Sendable (ActionArgs<Context>) -> SendableValue?)?
    public var onDone: TransitionInput<Context>?
    public var onError: TransitionInput<Context>?
    public var onSnapshot: TransitionInput<Context>?
    /// Restore behavior for opaque children (task / callback / taskGroup) when hydrating.
    public var opaqueRestorePolicy: OpaqueInvokeRestorePolicy
    /// When `false`, the child runs locally but is not registered with Stately Inspector.
    public var inspectable: Bool

    public var syncSnapshot: Bool { onSnapshot != nil }

    public init(
        id: String,
        src: ActorSource,
        systemId: String? = nil,
        input: (@Sendable (ActionArgs<Context>) -> SendableValue?)? = nil,
        onDone: TransitionInput<Context>? = nil,
        onError: TransitionInput<Context>? = nil,
        onSnapshot: TransitionInput<Context>? = nil,
        opaqueRestorePolicy: OpaqueInvokeRestorePolicy = .restart,
        inspectable: Bool = true
    ) {
        self.id = id
        self.src = src
        self.systemId = systemId
        self.input = input
        self.onDone = onDone
        self.onError = onError
        self.onSnapshot = onSnapshot
        self.opaqueRestorePolicy = opaqueRestorePolicy
        self.inspectable = inspectable
    }
}

public struct SpawnRef<Context: Sendable>: Sendable {
    public var src: ActorSource
    public var id: String?
    public var systemId: String?
    public var input: (@Sendable (ActionArgs<Context>) -> SendableValue?)?
    public var syncSnapshot: Bool
    /// When `false`, the child runs locally but is not registered with Stately Inspector.
    public var inspectable: Bool
    public var opaqueRestorePolicy: OpaqueInvokeRestorePolicy

    public init(
        src: ActorSource,
        id: String? = nil,
        systemId: String? = nil,
        input: (@Sendable (ActionArgs<Context>) -> SendableValue?)? = nil,
        syncSnapshot: Bool = false,
        inspectable: Bool = true,
        opaqueRestorePolicy: OpaqueInvokeRestorePolicy = .restart
    ) {
        self.src = src
        self.id = id
        self.systemId = systemId
        self.input = input
        self.syncSnapshot = syncSnapshot
        self.inspectable = inspectable
        self.opaqueRestorePolicy = opaqueRestorePolicy
    }
}

func processOnDoneConfig<Context: Sendable>(
    _ onDone: TransitionInput<Context>,
    stateNode: StateNode<Context>
) {
    let eventType = createDoneStateEventType(stateNode.id)
    let transitions = resolveTransitionConfigs(onDone)
    stateNode.transitions[eventType, default: []].append(
        contentsOf: transitions.map { ResolvedTransition(config: $0, source: stateNode) }
    )
}

func processInvokeConfig<Context: Sendable>(
    _ invoke: [InvokeConfig<Context>],
    stateNode: StateNode<Context>
) {
    for config in invoke {
        if let onDone = config.onDone {
            let eventType = createDoneActorEventType(config.id)
            let transitions = resolveTransitionConfigs(onDone)
            stateNode.transitions[eventType, default: []].append(
                contentsOf: transitions.map { ResolvedTransition(config: $0, source: stateNode) }
            )
        }

        if let onError = config.onError {
            let eventType = createErrorActorEventType(config.id)
            let transitions = resolveTransitionConfigs(onError)
            stateNode.transitions[eventType, default: []].append(
                contentsOf: transitions.map { ResolvedTransition(config: $0, source: stateNode) }
            )
        }

        if let onSnapshot = config.onSnapshot {
            let eventType = createSnapshotActorEventType(config.id)
            let transitions = resolveTransitionConfigs(onSnapshot)
            stateNode.transitions[eventType, default: []].append(
                contentsOf: transitions.map { ResolvedTransition(config: $0, source: stateNode) }
            )
        }
    }
}

struct ResolvedActorSource {
    var machine: MachineActorLogicBox?
    var task: TaskActorLogicBox?
    var callback: CallbackActorLogicBox?
    var taskGroup: TaskGroupActorLogicBox?
    var transition: TransitionActorLogicBox?
    var observable: ObservableActorLogicBox?
    var store: StoreActorLogicBox?
    var named: String?
}

func resolveActorSource<Context: Sendable>(
    _ source: ActorSource,
    implementations: MachineImplementations<Context>
) -> ResolvedActorSource {
    switch source {
    case let .named(name):
        guard let logic = implementations.actors[name] else {
            return ResolvedActorSource(named: name)
        }
        return ResolvedActorSource(
            machine: logic.machine,
            task: logic.task,
            callback: logic.callback,
            taskGroup: logic.taskGroup,
            transition: logic.transition,
            observable: logic.observable,
            store: logic.store
        )
    case let .machine(box):
        return ResolvedActorSource(machine: box)
    case let .task(box):
        return ResolvedActorSource(task: box)
    case let .callback(box):
        return ResolvedActorSource(callback: box)
    case let .taskGroup(box):
        return ResolvedActorSource(taskGroup: box)
    case let .transition(box):
        return ResolvedActorSource(transition: box)
    case let .observable(box):
        return ResolvedActorSource(observable: box)
    case let .store(box):
        return ResolvedActorSource(store: box)
    }
}

func spawnChild<Context: Sendable>(
    from source: ActorSource,
    id: String,
    systemId: String?,
    input: SendableValue?,
    syncSnapshot: Bool,
    inspectable: Bool,
    parent: any ActorParentRef,
    implementations: MachineImplementations<Context>,
    options: ActorOptions,
    persistedChild: PersistedChildSnapshot? = nil,
    opaqueRestorePolicy: OpaqueInvokeRestorePolicy = .restart,
    children: inout [String: any ChildActorRef]
) {
    let resolved = resolveActorSource(source, implementations: implementations)
    var childOptions = options
    childOptions.systemId = systemId ?? id
    childOptions.inspectable = inspectable

    let resolvedSystemId = systemId ?? id

    if let machine = resolved.machine {
        let child = machine.spawn(
            id: id,
            input: input,
            parent: parent,
            options: childOptions,
            syncSnapshot: syncSnapshot,
            persistedChild: persistedChild
        )
        children[id] = child
        parent.actorSystem.register(child)
        if inspectable {
            parent.inspectSpawnedChild(child, machineId: child.machineId)
        }
        child.start()
        return
    }

    if let task = resolved.task {
        guard shouldSpawnOpaqueChild(persistedChild: persistedChild, policy: opaqueRestorePolicy) else {
            return
        }
        let child = task.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId
        )
        children[id] = child
        parent.actorSystem.register(child)
        parent.inspectSpawnedChild(child, machineId: nil)
        child.start()
        return
    }

    if let callback = resolved.callback {
        guard shouldSpawnOpaqueChild(persistedChild: persistedChild, policy: opaqueRestorePolicy) else {
            return
        }
        let child = callback.spawn(
            id: id,
            input: input,
            parent: parent,
            system: parent.actorSystem,
            systemId: resolvedSystemId
        )
        children[id] = child
        parent.actorSystem.register(child)
        parent.inspectSpawnedChild(child, machineId: nil)
        child.start()
        return
    }

    if let taskGroup = resolved.taskGroup {
        guard shouldSpawnOpaqueChild(persistedChild: persistedChild, policy: opaqueRestorePolicy) else {
            return
        }
        let child = taskGroup.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId
        )
        children[id] = child
        parent.actorSystem.register(child)
        parent.inspectSpawnedChild(child, machineId: nil)
        child.start()
        return
    }

    if let transition = resolved.transition {
        let child = transition.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId,
            syncSnapshot: syncSnapshot
        )
        children[id] = child
        parent.actorSystem.register(child)
        parent.inspectSpawnedChild(child, machineId: nil)
        child.start()
        return
    }

    if let observable = resolved.observable {
        let child = observable.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId,
            syncSnapshot: syncSnapshot
        )
        children[id] = child
        parent.actorSystem.register(child)
        parent.inspectSpawnedChild(child, machineId: nil)
        child.start()
        return
    }

    if let store = resolved.store {
        let child = store.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId,
            syncSnapshot: syncSnapshot
        )
        children[id] = child
        parent.actorSystem.register(child)
        parent.inspectSpawnedChild(child, machineId: nil)
        child.start()
        return
    }

    if let name = resolved.named {
        fatalError("Actor logic '\(name)' not found. Register it via setup(actors:) or MachineImplementations.actors.")
    }
}

/// An action that spawns a child actor from an `ActorSource` (`fromTask`, `fromCallback`, a child
/// machine, or a `.named` registered actor). `input` seeds the child's context; `syncSnapshot`
/// streams the child's snapshots back to the parent. XState's `spawnChild`.
public func spawnChild<Context: Sendable>(
    _ src: ActorSource,
    id: String? = nil,
    systemId: String? = nil,
    input: (@Sendable (ActionArgs<Context>) -> SendableValue?)? = nil,
    syncSnapshot: Bool = false,
    inspectable: Bool = true
) -> ActionRef<Context> {
    .spawn(
        SpawnRef(
            src: src,
            id: id,
            systemId: systemId,
            input: input,
            syncSnapshot: syncSnapshot,
            inspectable: inspectable
        )
    )
}

/// An action that sends an event to this actor's parent. XState's `sendParent`.
public func sendParent<Context: Sendable>(_ event: Event) -> ActionRef<Context> {
    .sendParent(event)
}

/// An action that stops the spawned/invoked child actor with the given id.
public func stopChild<Context: Sendable>(_ id: String) -> ActionRef<Context> {
    .stopChild(.fixed(id))
}

/// Stops a child actor whose id is resolved at runtime.
public func stopChild<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String
) -> ActionRef<Context> {
    .stopChild(.expression(expression))
}

/// Stops a child actor. Alias for `stopChild`, matching XState's deprecated `stop` export.
public func stop<Context: Sendable>(_ id: String) -> ActionRef<Context> {
    stopChild(id)
}

/// Stops a child actor whose id is resolved at runtime.
public func stop<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String
) -> ActionRef<Context> {
    stopChild(expression)
}