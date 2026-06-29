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
        any ParentActorRepresentable,
        String?,
        Bool
    ) -> any ChildActorRepresentable

    public init<Context: Sendable & Equatable>(_ logic: ObservableActorLogic<Context>) {
        _spawn = { id, input, parent, systemId, syncSnapshot in
            let actor = Actor(
                ObservableLogic(logic: logic, syncSnapshot: syncSnapshot, system: parent.actorSystem),
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
