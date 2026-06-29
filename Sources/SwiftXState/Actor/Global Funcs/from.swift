/// Actor logic backed by an `async` task — XState's `fromPromise`. The returned `Output` becomes
/// the child's `done` data (drives `onDone`); throwing drives `onError`; `onCancel` runs if the
/// invoking state exits first. Use as an `invoke` `src` or with `spawnChild`.
public func fromTask<Output: Sendable & Equatable>(
    _ run: @escaping @Sendable (TaskActorScope) async throws -> Output,
    onCancel: (@Sendable (TaskActorScope) async -> Void)? = nil
) -> ActorSource {
    .task(TaskActorLogicBox(TaskActorLogic(run: run, onCancel: onCancel)))
}

/// `fromTask` with the `onCancel` handler supplied first (trailing-closure ergonomics).
public func fromTask<Output: Sendable & Equatable>(
    onCancel: @escaping @Sendable (TaskActorScope) async -> Void,
    _ run: @escaping @Sendable (TaskActorScope) async throws -> Output
) -> ActorSource {
    fromTask(run, onCancel: onCancel)
}

/// Actor logic backed by a long-lived callback — XState's `fromCallback`. `run` receives a scope
/// to `send` events back to the parent and returns an optional cleanup closure run on stop.
public func fromCallback(
    _ run: @escaping @Sendable (CallbackActorScope) -> (@Sendable () -> Void)?
) -> ActorSource {
    .callback(CallbackActorLogicBox(CallbackActorLogic(run: run)))
}

public func fromTaskGroup<Output: Sendable & Equatable>(
    _ run: @escaping @Sendable (TaskGroupScope) async throws -> [Output],
    onCancel: (@Sendable (TaskGroupScope) async -> Void)? = nil
) -> ActorSource {
    .taskGroup(TaskGroupActorLogicBox(TaskGroupActorLogic(run: run, onCancel: onCancel)))
}

public func fromTaskGroup<Output: Sendable & Equatable>(
    onCancel: @escaping @Sendable (TaskGroupScope) async -> Void,
    _ run: @escaping @Sendable (TaskGroupScope) async throws -> [Output]
) -> ActorSource {
    fromTaskGroup(run, onCancel: onCancel)
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: ResolvedMachine<ChildContext>
) -> ActorSource {
    .machine(MachineActorLogicBox(machine))
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: ResolvedMachine<ChildContext>,
    context: @escaping @Sendable (SendableValue?) -> ChildContext
) -> ActorSource {
    .machine(MachineActorLogicBox(machine, context: context))
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: ResolvedMachine<ChildContext>,
    context: ChildContext
) -> ActorSource {
    .machine(MachineActorLogicBox(machine, context: { _ in context }))
}

/// Returns store actor logic compatible with `createActor` / `spawnChild`.
public func fromStore<Context: Sendable & Equatable, E: Eventable>(
    _ logic: StoreLogic<Context, E>
) -> ActorSource {
    .store(StoreActorLogicBox(StoreActorLogic(logic)))
}

/// Convenience for inline store configs.
public func fromStore<Context: Sendable & Equatable, E: Eventable>(
    context: Context,
    on: [String: StoreMutator<Context, E>] = [:],
    assign: [String: StoreAssigner<Context, E>] = [:]
) -> ActorSource {
    fromStore(createStoreLogic(context: context, on: on, assign: assign))
}

/// Convenience with input-derived context.
public func fromStore<Context: Sendable & Equatable, E: Eventable>(
    context: @escaping @Sendable (SendableValue?) -> Context,
    on: [String: StoreMutator<Context, E>] = [:],
    assign: [String: StoreAssigner<Context, E>] = [:]
) -> ActorSource {
    fromStore(createStoreLogic(context: context, on: on, assign: assign))
}

/// Returns transition actor logic with a fixed initial context.
public func fromTransition<Context: Sendable & Equatable>(
    _ transition: @escaping @Sendable (Context, any Eventable, TransitionActorScope) -> Context,
    initialContext: Context
) -> ActorSource {
    .transition(TransitionActorLogicBox(TransitionActorLogic(
        transition: transition,
        resolveInitialContext: { _ in initialContext }
    )))
}

/// Returns transition actor logic with initial context derived from input.
public func fromTransition<Context: Sendable & Equatable>(
    _ transition: @escaping @Sendable (Context, any Eventable, TransitionActorScope) -> Context,
    initialContext: @escaping @Sendable (SendableValue?) -> Context
) -> ActorSource {
    .transition(TransitionActorLogicBox(TransitionActorLogic(
        transition: transition,
        resolveInitialContext: initialContext
    )))
}
