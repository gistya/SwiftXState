/// Reducer-style actor logic, mirroring XState's `fromTransition`.
public struct TransitionActorLogic<Context: Sendable & Equatable>: Sendable {
    public let transition: @Sendable (Context, any Eventable, TransitionActorScope) -> Context
    public let resolveInitialContext: @Sendable (SendableValue?) -> Context

    public init(
        transition: @escaping @Sendable (Context, any Eventable, TransitionActorScope) -> Context,
        resolveInitialContext: @escaping @Sendable (SendableValue?) -> Context
    ) {
        self.transition = transition
        self.resolveInitialContext = resolveInitialContext
    }
}

/// Type-erased transition actor logic.
public struct TransitionActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?,
        Bool
    ) -> any ChildActor

    public init<Context: Sendable & Equatable>(_ logic: TransitionActorLogic<Context>) {
        _spawn = { id, input, parent, systemId, syncSnapshot in
            let actor = Actor(
                TransitionLogic(logic: logic, syncSnapshot: syncSnapshot),
                id: id,
                options: ActorOptions(systemId: systemId),
                parent: parent,
                system: parent.actorSystem
            )
            return LogicChildActor(actor: actor, id: id, systemId: systemId, input: input, inspectable: true)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        systemId: String?,
        syncSnapshot: Bool
    ) -> any ChildActor {
        _spawn(id, input, parent, systemId, syncSnapshot)
    }
}
