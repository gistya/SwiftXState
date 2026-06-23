/// Observable stream actor logic, mirroring XState's `fromObservable`.
public struct ObservableActorLogic<Context: Sendable & Equatable>: Sendable {
    public let create: @Sendable (ObservableActorScope) -> AnySubscribable<Context>

    public init(
        create: @escaping @Sendable (ObservableActorScope) -> AnySubscribable<Context>
    ) {
        self.create = create
    }
}

/// Type-erased observable actor logic.
public struct ObservableActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?,
        Bool
    ) -> any ChildActorRef

    public init<Context: Sendable & Equatable>(_ logic: ObservableActorLogic<Context>) {
        _spawn = { id, input, parent, systemId, syncSnapshot in
            ObservableChildRef(
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
    ) -> any ChildActorRef {
        _spawn(id, input, parent, systemId, syncSnapshot)
    }
}
