final class TransitionChildRef<Context: Sendable & Equatable>: ChildActor, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: TransitionActorLogic<Context>
    private let input: SendableValue?
    private let syncSnapshot: Bool
    private let emitListeners = EmitListeners()
    private var context: Context
    private(set) var status: SnapshotStatus = .stopped

    var definitionJSON: String? { nil }

    init(
        id: String,
        systemId: String?,
        input: SendableValue?,
        parent: any ActorParentRef,
        logic: TransitionActorLogic<Context>,
        syncSnapshot: Bool
    ) {
        self.id = id
        self.systemId = systemId
        self.input = input
        self.parent = parent
        self.logic = logic
        self.syncSnapshot = syncSnapshot
        self.context = logic.resolveInitialContext(input)
    }

    func start() async {
        guard status == .stopped else { return }
        status = .active
        context = logic.resolveInitialContext(input)
        let snapshotValue = String(describing: context)

        if syncSnapshot {
            let parent = self.parent
            Task {
                await parent?.enqueueFromChild(
                    SnapshotActorEvent(
                        actorId: id,
                        snapshot: ChildActorSnapshot(
                            id: id,
                            status: .active,
                            value: snapshotValue
                        )
                    )
                )
            }
        }
    }

    func stop() async {
        status = .stopped
        emitListeners.removeAll()
    }

    func send(_ event: any Eventable) async {
        guard status == .active else { return }

        let parent = self.parent
        let system = parent?.actorSystem ?? ActorSystem()
        let scope = TransitionActorScope(
            input: input,
            system: system,
            sendToParent: { childEvent in
                Task {
                    await parent?.enqueueFromChild(childEvent)
                }
            },
            emit: { [emitListeners] emitted in
                emitListeners.notify(emitted)
            }
        )
        context = logic.transition(context, event, scope)
        let snapshotValue = String(describing: context)

        if syncSnapshot {
            await parent?.enqueueFromChild(
                SnapshotActorEvent(
                    actorId: id,
                    snapshot: ChildActorSnapshot(
                        id: id,
                        status: .active,
                        value: snapshotValue
                    )
                )
            )
        }
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }
}
