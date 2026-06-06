import Foundation

/// Scope passed to observable actor logic (`fromObservable`).
public struct ObservableActorScope: Sendable {
    public let input: SendableValue?
    public let system: ActorSystem
    public let emit: @Sendable (EmittedEvent) -> Void

    public init(
        input: SendableValue?,
        system: ActorSystem,
        emit: @escaping @Sendable (EmittedEvent) -> Void
    ) {
        self.input = input
        self.system = system
        self.emit = emit
    }
}

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

final class ObservableChildRef<Context: Sendable & Equatable>: ChildActorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: ObservableActorLogic<Context>
    private let input: SendableValue?
    private let syncSnapshot: Bool
    private let emitListeners = EmitListeners()
    private let lock = NSLock()
    private var subscription: Subscription?
    private var doneSent = false
    private var context: Context?
    private(set) var status: SnapshotStatus = .stopped
    private(set) var lastError: String?

    var errorMessage: String? { lastError }
    var definitionJSON: String? { nil }

    init(
        id: String,
        systemId: String?,
        input: SendableValue?,
        parent: any ActorParentRef,
        logic: ObservableActorLogic<Context>,
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
        lock.lock()
        guard subscription == nil, status != .done else {
            lock.unlock()
            return
        }
        status = .active
        lastError = nil
        doneSent = false
        lock.unlock()

        let scope = ObservableActorScope(
            input: input,
            system: parent?.actorSystem ?? ActorSystem(),
            emit: { [emitListeners] event in
                emitListeners.notify(event)
            }
        )

        let stream = logic.create(scope)
        subscription = stream.subscribe(
            next: { [weak self] value in
                self?.handleNext(value)
            },
            onError: { [weak self] message in
                self?.handleError(message)
            },
            onComplete: { [weak self] in
                self?.handleComplete()
            }
        )
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        lock.lock()
        status = .stopped
        lastError = nil
        lock.unlock()
        emitListeners.removeAll()
    }

    func send(_: any Eventable) {}

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }

    private func handleNext(_ value: Context) {
        lock.lock()
        guard status == .active else {
            lock.unlock()
            return
        }
        context = value
        let snapshotValue = String(describing: value)
        lock.unlock()

        if syncSnapshot {
            parent?.enqueueFromChild(
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

    private func handleError(_ message: String) {
        lock.lock()
        guard !doneSent else {
            lock.unlock()
            return
        }
        doneSent = true
        status = .error
        lastError = message
        lock.unlock()

        subscription?.cancel()
        subscription = nil

        parent?.enqueueFromChild(
            ErrorActorEvent(actorId: id, error: message)
        )
    }

    private func handleComplete() {
        lock.lock()
        guard !doneSent else {
            lock.unlock()
            return
        }
        doneSent = true
        status = .done
        let output = context.map { SendableValue($0) }
        lock.unlock()

        subscription?.cancel()
        subscription = nil

        parent?.enqueueFromChild(
            DoneActorEvent(actorId: id, output: output)
        )
    }
}

/// Returns observable actor logic from a subscribable creator.
public func fromObservable<Context: Sendable & Equatable>(
    _ observableCreator: @escaping @Sendable (ObservableActorScope) -> any Subscribable<Context>
) -> ActorSource {
    .observable(ObservableActorLogicBox(ObservableActorLogic { scope in
        AnySubscribable(observableCreator(scope))
    }))
}

/// Returns observable actor logic from a type-erased subscribable creator.
public func fromObservable<Context: Sendable & Equatable>(
    _ observableCreator: @escaping @Sendable (ObservableActorScope) -> AnySubscribable<Context>
) -> ActorSource {
    .observable(ObservableActorLogicBox(ObservableActorLogic(create: observableCreator)))
}