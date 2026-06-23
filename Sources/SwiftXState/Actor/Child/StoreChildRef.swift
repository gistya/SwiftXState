final class StoreChildRef<Context: Sendable & Equatable, E: Eventable>: ChildActorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: StoreActorLogic<Context, E>
    private let input: SendableValue?
    private let syncSnapshot: Bool
    private let emitListeners = EmitListeners()
    private var store: Store<Context, E>?
    private(set) var status: SnapshotStatus = .stopped

    var definitionJSON: String? { nil }

    init(
        id: String,
        systemId: String?,        input: SendableValue?,
        parent: any ActorParentRef,
        logic: StoreActorLogic<Context, E>,
        syncSnapshot: Bool
    ) {
        self.id = id
        self.systemId = systemId
        self.input = input
        self.parent = parent
        self.logic = logic
        self.syncSnapshot = syncSnapshot
    }

    func start() async {
        guard status == .stopped else { return }
        store = logic.logic.createStore(input: input)
        status = .active
        await publishSnapshot()
    }

    func stop() async {
        store?.stop()
        status = .stopped
        emitListeners.removeAll()
    }

    func send(_ event: any Eventable) async {
        guard status == .active, let store else { return }
        guard let typed = event as? E else { return }
        store.send(typed)
        await publishSnapshot()
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        if let store {
            return store.on(eventType, handler: handler)
        }
        return emitListeners.on(eventType, handler: handler)
    }

    private func publishSnapshot() async {
        guard syncSnapshot, let store else { return }
        await parent?.enqueueFromChild(
            SnapshotActorEvent(
                actorId: id,
                snapshot: ChildActorSnapshot(
                    id: id,
                    status: .active,
                    value: String(describing: store.context)
                )
            )
        )
    }
}
