// TODO: Refactor into static methods on Actor

/// Creates an actor (a runnable instance) from a machine — the Swift equivalent of XState's
/// `createActor(machine)`. Call `.start()` on the result to run it. Pass `inspect:` to stream
/// inspection events, or `input:` to seed the initial context via `contextFromInput`.
public func createActor<Context: Sendable>(
    _ machine: StateMachine<Context>,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    input: SendableValue? = nil,
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> Actor<MachineLogic<Context>> {
    var resolvedOptions = options
    if let input {
        resolvedOptions.input = input
    }
    if let inspect {
        resolvedOptions.inspect = inspect
    }
    return Actor(machine, id: id, options: resolvedOptions)
}

/// Creates an actor branded with a compile-time state family `Brand`, returning a `TypedActor`
/// whose `snapshot` / `start` / `send` yield `Brand`-typed `TypedSnapshot`s (`inState(_:)` /
/// `narrowed(to:)`). Brand at creation instead of the post-hoc `createActor(machine).typed(as:)`
/// two-step; otherwise identical to `createActor(_:)`.
public func createActor<Context: Sendable, Brand: StateID>(
    _ machine: StateMachine<Context>,
    as _: Brand.Type,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    input: SendableValue? = nil,
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> TypedActor<Context, Brand> {
    TypedActor(createActor(machine, id: id, options: options, input: input, inspect: inspect))
}

/// Creates an actor and hydrates it from a persisted snapshot in one step.
///
/// The returned actor is already started — equivalent to
/// `createActor(machine).start(from: snapshot)`, including child re-spawn and
/// delayed-transition scheduling for restored state nodes.
public func createActor<Context: Codable & Sendable>(
    _ machine: StateMachine<Context>,
    snapshot: PersistedSnapshot,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    context: Context? = nil,
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) async -> Actor<MachineLogic<Context>> {
    var resolvedOptions = options
    if let inspect {
        resolvedOptions.inspect = inspect
    }
    let actor = Actor<MachineLogic<Context>>(machine, id: id, options: resolvedOptions)
    await actor.start(from: snapshot, context: context)
    return actor
}

/// Brand-tagged variant of `createActor(_:snapshot:)`; the hydrated actor is wrapped in a
/// `Brand`-typed `TypedActor`.
public func createActor<Context: Codable & Sendable, Brand: StateID>(
    _ machine: StateMachine<Context>,
    as _: Brand.Type,
    snapshot: PersistedSnapshot,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    context: Context? = nil,
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) async -> TypedActor<Context, Brand> {
    TypedActor(
        await createActor(
            machine,
            snapshot: snapshot,
            id: id,
            options: options,
            context: context,
            inspect: inspect
        )
    )
}

/// Creates an actor with typed `input` (any `Sendable & Equatable`), wrapped into the machine's
/// `contextFromInput`. Convenience over passing a `SendableValue`.
public func createActor<Context: Sendable, Input: Sendable & Equatable>(
    _ machine: StateMachine<Context>,
    input: Input,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> Actor<MachineLogic<Context>> {
    createActor(
        machine,
        id: id,
        options: options,
        input: SendableValue(input),
        inspect: inspect
    )
}

/// Brand-tagged variant of `createActor(_:input:)`.
public func createActor<Context: Sendable, Input: Sendable & Equatable, Brand: StateID>(
    _ machine: StateMachine<Context>,
    as _: Brand.Type,
    input: Input,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> TypedActor<Context, Brand> {
    TypedActor(createActor(machine, input: input, id: id, options: options, inspect: inspect))
}
