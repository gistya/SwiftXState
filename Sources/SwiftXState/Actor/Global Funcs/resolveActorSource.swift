/// Resolves an `ActorSource` (named lookup or inline box) into the concrete logic kinds
/// `makeChildActor` dispatches over. Free function for the same reason as the factory above.
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
