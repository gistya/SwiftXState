/// Store-backed actor logic, mirroring XState's `fromStore`.
public struct StoreActorLogic<Context: Sendable & Equatable, E: Eventable>: Sendable {
    public let logic: StoreLogic<Context, E>

    public init(_ logic: StoreLogic<Context, E>) {
        self.logic = logic
    }
}

/// Type-erased store actor logic.
public struct StoreActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?,
        Bool
    ) -> any ChildActor

    public init<Context: Sendable & Equatable, E: Eventable>(_ logic: StoreActorLogic<Context, E>) {
        _spawn = { id, input, parent, systemId, syncSnapshot in
            StoreChildRef(
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
