import Foundation

/// The concrete logic kinds an `ActorSource` resolves to. Exactly one box is non-nil (or `named`,
/// for an unresolved lookup). Was nested in `Actor`; lifted alongside the factory functions below.
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

/// Builds child actor references for `invoke` / `spawn`, given a resolved actor source.
///
/// Lifted out of `Actor` (it used no actor state — only the `Context` generic for
/// `implementations`, plus free helpers) so the generics refactor's `StateActor` can spawn children
/// through the exact same factory rather than a duplicate. The `parent` is type-erased to
/// `any ActorParentRef`, so any actor that can parent children drives identical child creation.
func makeChildActorRef<Context: Sendable>(
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
    opaqueRestorePolicy: OpaqueInvokeRestorePolicy = .restart
) -> (any ChildActorRef)? {
    let resolved = resolveActorSource(source, implementations: implementations)
    var childOptions = options
    childOptions.systemId = systemId ?? id
    childOptions.inspectable = inspectable

    let resolvedSystemId = systemId ?? id

    if let machine = resolved.machine {
        return machine.spawn(
            id: id,
            input: input,
            parent: parent,
            options: childOptions,
            syncSnapshot: syncSnapshot,
            persistedChild: persistedChild
        )
    }

    if let task = resolved.task {
        guard shouldSpawnOpaqueChild(persistedChild: persistedChild, policy: opaqueRestorePolicy) else {
            return nil
        }
        return task.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId
        )
    }

    if let callback = resolved.callback {
        guard shouldSpawnOpaqueChild(persistedChild: persistedChild, policy: opaqueRestorePolicy) else {
            return nil
        }
        return callback.spawn(
            id: id,
            input: input,
            parent: parent,
            system: parent.actorSystem,
            systemId: resolvedSystemId
        )
    }

    if let taskGroup = resolved.taskGroup {
        guard shouldSpawnOpaqueChild(persistedChild: persistedChild, policy: opaqueRestorePolicy) else {
            return nil
        }
        return taskGroup.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId
        )
    }

    if let transition = resolved.transition {
        return transition.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId,
            syncSnapshot: syncSnapshot
        )
    }

    if let observable = resolved.observable {
        return observable.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId,
            syncSnapshot: syncSnapshot
        )
    }

    if let store = resolved.store {
        return store.spawn(
            id: id,
            input: input,
            parent: parent,
            systemId: resolvedSystemId,
            syncSnapshot: syncSnapshot
        )
    }

    if let name = resolved.named {
        fatalError("Actor logic '\(name)' not found. Register it via setup(actors:) or MachineImplementations.actors.")
    }

    return nil
}

/// Resolves an `ActorSource` (named lookup or inline box) into the concrete logic kinds
/// `makeChildActorRef` dispatches over. Free function for the same reason as the factory above.
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
