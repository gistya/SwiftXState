final class MachineChildRef<ChildContext: Sendable>: ChildActor, @unchecked Sendable {
    let actor: Actor<ChildContext>
    private weak var parent: (any ActorParentRef)?
    private var subscription: Subscription?
    private var lastSnapshot: MachineSnapshot<ChildContext>?
    private var doneSent = false
    private let initialContext: ChildContext
    private let syncSnapshot: Bool
    private let persistedRestore: PersistedSnapshot?
    private let onRestore: (@Sendable (PersistedSnapshot) async -> Void)?

    let id: String
    let systemId: String?
    var inspectable: Bool { actor.isInspectable }
    var machineId: String? { actor.machine.id }
    var definitionJSON: String? { try? actor.machine.definitionJSON() }
    var snapshotValue: String? { lastSnapshot?.value.description }

    var status: SnapshotStatus {
        lastSnapshot?.status ?? .stopped
    }

    init(
        actor: Actor<ChildContext>,
        systemId: String?,
        parent: any ActorParentRef,
        context: ChildContext,
        syncSnapshot: Bool = false,
        persistedRestore: PersistedSnapshot? = nil,
        onRestore: (@Sendable (PersistedSnapshot) async -> Void)? = nil
    ) {
        self.actor = actor
        self.id = actor.id
        self.systemId = systemId
        self.parent = parent
        self.initialContext = context
        self.syncSnapshot = syncSnapshot
        self.persistedRestore = persistedRestore
        self.onRestore = onRestore
    }

    func start() async {
        if let persistedRestore, let onRestore {
            await onRestore(persistedRestore)
            if persistedRestore.status == .done {
                doneSent = true
            }
        } else {
            await actor.start(context: initialContext)
        }
        lastSnapshot = await actor.snapshot
        subscription = await actor.subscribe { [weak self] snapshot in
            guard let self else { return }
            lastSnapshot = snapshot

            if syncSnapshot, snapshot.status == .active {
                Task { [weak parent] in
                    await parent?.enqueueFromChild(
                        SnapshotActorEvent(
                            actorId: id,
                            snapshot: ChildActorSnapshot(
                                id: id,
                                status: snapshot.status,
                                value: snapshot.value.description
                            )
                        )
                    )
                }
            }

            guard !doneSent, snapshot.status == .done else { return }
            doneSent = true
            Task { [weak parent] in
                await parent?.enqueueFromChild(
                    DoneActorEvent(
                        actorId: id,
                        output: snapshot.output
                    )
                )
            }
        }
    }

    func stop() async {
        subscription?.cancel()
        subscription = nil
        await actor.stop()
        lastSnapshot = await actor.status == .stopped ? lastSnapshot : await actor.snapshot
    }

    func send(_ event: any Eventable) async {
        await actor.send(event)
        lastSnapshot = await actor.snapshot
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        await actor.on(eventType, handler: handler)
    }
}

extension MachineChildRef: PersistedChildSnapshotProviding where ChildContext: Codable {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot? {
        .machine(try await actor.getPersistedSnapshot())
    }
}
