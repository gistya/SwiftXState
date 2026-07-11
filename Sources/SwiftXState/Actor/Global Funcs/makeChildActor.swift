
/// Builds child actor references for `invoke` / `spawn`, given a resolved actor source.
///
/// Lifted out of `Actor` (it used no actor state — only the `Context` generic for
/// `implementations`, plus free helpers) so the generics refactor's `StateActor` can spawn children
/// through the exact same factory rather than a duplicate. The `parent` is type-erased to
/// `any ParentActorRepresentable`, so any actor that can parent children drives identical child creation.
func makeChildActor<Context: Sendable>(
    from source: ActorSource,
    id: String,
    systemId: String?,
    input: SendableValue?,
    syncSnapshot: Bool,
    inspectable: Bool,
    parent: any ParentActorRepresentable,
    implementations: MachineImplementations<Context>,
    options: ActorOptions,
    persistedChild: PersistedChildSnapshot? = nil,
    opaqueRestorePolicy: OpaqueInvokeRestorePolicy = .restart
) -> (any ChildActorRepresentable)? {
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


