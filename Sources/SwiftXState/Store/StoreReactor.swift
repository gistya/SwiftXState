import Foundation

/// Store-backed reactor logic, mirroring XState's `fromStore`.
public struct StoreReactorLogic<Context: Sendable & Equatable, E: Eventable>: Sendable {
    public let logic: StoreLogic<Context, E>

    public init(_ logic: StoreLogic<Context, E>) {
        self.logic = logic
    }
}

/// Type-erased store actor logic.
public struct StoreReactorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ReactorParentRef,
        String?,
        Bool
    ) -> any ChildReactorRef

    public init<Context: Sendable & Equatable, E: Eventable>(_ logic: StoreReactorLogic<Context, E>) {
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
        parent: any ReactorParentRef,
        systemId: String?,
        syncSnapshot: Bool
    ) -> any ChildReactorRef {
        _spawn(id, input, parent, systemId, syncSnapshot)
    }
}

final class StoreChildRef<Context: Sendable & Equatable, E: Eventable>: ChildReactorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ReactorParentRef)?
    private let logic: StoreReactorLogic<Context, E>
    private let input: SendableValue?
    private let syncSnapshot: Bool
    private let emitListeners = EmitListeners()
    private var store: Store<Context, E>?
    private(set) var status: SnapshotStatus = .stopped

    var definitionJSON: String? { nil }

    init(
        id: String,
        systemId: String?,
        input: SendableValue?,
        parent: any ReactorParentRef,
        logic: StoreReactorLogic<Context, E>,
        syncSnapshot: Bool
    ) {
        self.id = id
        self.systemId = systemId
        self.input = input
        self.parent = parent
        self.logic = logic
        self.syncSnapshot = syncSnapshot
    }

    func start() {
        guard status == .stopped else { return }
        store = logic.logic.createStore(input: input)
        status = .active
        publishSnapshot()
    }

    func stop() {
        store?.stop()
        status = .stopped
        emitListeners.removeAll()
    }

    func send(_ event: any Eventable) {
        guard status == .active, let store else { return }
        guard let typed = event as? E else { return }
        store.send(typed)
        publishSnapshot()
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        if let store {
            return store.on(eventType, handler: handler)
        }
        return emitListeners.on(eventType, handler: handler)
    }

    private func publishSnapshot() {
        guard syncSnapshot, let store else { return }
        parent?.enqueueFromChild(
            SnapshotReactorEvent(
                actorId: id,
                snapshot: ChildReactorSnapshot(
                    id: id,
                    status: .active,
                    value: String(describing: store.context)
                )
            )
        )
    }
}

/// Returns store actor logic compatible with `createReactor` / `spawnChild`.
public func fromStore<Context: Sendable & Equatable, E: Eventable>(
    _ logic: StoreLogic<Context, E>
) -> ReactorSource {
    .store(StoreReactorLogicBox(StoreReactorLogic(logic)))
}

/// Convenience for inline store configs.
public func fromStore<Context: Sendable & Equatable, E: Eventable>(
    context: Context,
    on: [String: StoreMutator<Context, E>] = [:],
    assign: [String: StoreAssigner<Context, E>] = [:]
) -> ReactorSource {
    fromStore(createStoreLogic(context: context, on: on, assign: assign))
}

/// Convenience with input-derived context.
public func fromStore<Context: Sendable & Equatable, E: Eventable>(
    context: @escaping @Sendable (SendableValue?) -> Context,
    on: [String: StoreMutator<Context, E>] = [:],
    assign: [String: StoreAssigner<Context, E>] = [:]
) -> ReactorSource {
    fromStore(createStoreLogic(context: context, on: on, assign: assign))
}
