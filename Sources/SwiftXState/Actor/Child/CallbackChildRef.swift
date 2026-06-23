import Foundation   

final class CallbackChildRef: ChildActorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: CallbackActorLogic
    private let input: SendableValue?
    private let system: ActorSystem
    private let emitListeners = EmitListeners()
    private let parentDeliveries = ParentDeliveryChain()
    private var receivers: [@Sendable (any Eventable) -> Void] = []
    private var dispose: (@Sendable () -> Void)?
    private let lock = NSLock()
    private(set) var status: SnapshotStatus = .stopped
    var definitionJSON: String? { nil }

    init(
        id: String,
        systemId: String?,
        input: SendableValue?,
        parent: any ActorParentRef,
        logic: CallbackActorLogic,
        system: ActorSystem
    ) {
        self.id = id
        self.systemId = systemId
        self.input = input
        self.parent = parent
        self.logic = logic
        self.system = system
    }

    func start() async {
        guard dispose == nil else { return }
        status = .active

        let scope = CallbackActorScope(
            input: input,
            sendToParent: { [weak self] event in
                guard let self else { return }
                self.parentDeliveries.deliver(to: self.parent, event)
            },
            receive: { [weak self] listener in
                self?.lock.withLock {
                    self?.receivers.append(listener)
                }
            },
            emit: { [emitListeners] event in
                emitListeners.notify(event)
            },
            system: system
        )

        dispose = logic.run(scope)
    }

    func stop() async {
        dispose?()
        dispose = nil
        lock.withLock {
            receivers.removeAll()
        }
        status = .stopped
        emitListeners.removeAll()
    }

    func send(_ event: any Eventable) async {
        let listeners = lock.withLock {
            receivers
        }
        for listener in listeners {
            listener(event)
        }
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }
}

extension CallbackChildRef: PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot? {
        guard status != .stopped else { return nil }
        return .opaque(PersistedOpaqueChildSnapshot(status: status))
    }
}
