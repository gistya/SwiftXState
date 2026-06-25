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
            TransitionChildRef(
                id: id,
                systemId: systemId,
                input: input,
                parent: parent,
                logic: logic,
                syncSnapshot: syncSnapshot
            )
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

/// Scope passed to transition-based actor logic (`fromTransition`).
public struct TransitionActorScope {
    public let input: SendableValue?
    public let system: ActorSystem
    public let sendToParent: (any Eventable) -> Void
    public let emit: (EmittedEvent) -> Void

    public init(
        input: SendableValue?,
        system: ActorSystem,
        sendToParent: @escaping (any Eventable) -> Void,
        emit: @escaping (EmittedEvent) -> Void
    ) {
        self.input = input
        self.system = system
        self.sendToParent = sendToParent
        self.emit = emit
    }
}
