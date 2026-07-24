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
        any ParentActorRepresentable,
        String?,
        Bool
    ) -> any ChildActorRepresentable

    public init<Context: Sendable & Equatable, E: Eventable>(_ logic: StoreActorLogic<Context, E>) {
        _spawn = { id, input, parent, systemId, syncSnapshot in
            let actor = Actor(
                StoreChildLogic(logic: logic, syncSnapshot: syncSnapshot),
                id: id,
                options: ActorOptions(systemId: systemId),
                parent: parent,
                system: parent.actorSystem
            )
            return ChildActorBox(actor: actor, id: id, systemId: systemId, input: input, inspectable: true)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ParentActorRepresentable,
        systemId: String?,
        syncSnapshot: Bool
    ) -> any ChildActorRepresentable {
        _spawn(id, input, parent, systemId, syncSnapshot)
    }
}
