import Foundation

/// Scope passed to transition-based reactor logic (`fromTransition`).
public struct TransitionReactorScope: Sendable {
    public let input: SendableValue?
    public let system: ReactorSystem
    public let sendToParent: @Sendable (any Eventable) -> Void
    public let emit: @Sendable (EmittedEvent) -> Void

    public init(
        input: SendableValue?,
        system: ReactorSystem,
        sendToParent: @escaping @Sendable (any Eventable) -> Void,
        emit: @escaping @Sendable (EmittedEvent) -> Void
    ) {
        self.input = input
        self.system = system
        self.sendToParent = sendToParent
        self.emit = emit
    }
}

/// Reducer-style reactor logic, mirroring XState's `fromTransition`.
public struct TransitionReactorLogic<Context: Sendable & Equatable>: Sendable {
    public let transition: @Sendable (Context, any Eventable, TransitionReactorScope) -> Context
    public let resolveInitialContext: @Sendable (SendableValue?) -> Context

    public init(
        transition: @escaping @Sendable (Context, any Eventable, TransitionReactorScope) -> Context,
        resolveInitialContext: @escaping @Sendable (SendableValue?) -> Context
    ) {
        self.transition = transition
        self.resolveInitialContext = resolveInitialContext
    }
}

/// Type-erased transition reactor logic.
public struct TransitionReactorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ReactorParentRef,
        String?,
        Bool
    ) -> any ChildReactorRef

    public init<Context: Sendable & Equatable>(_ logic: TransitionReactorLogic<Context>) {
        _spawn = { id, input, parent, systemId, syncSnapshot in
            TransitionChildRef(
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

final class TransitionChildRef<Context: Sendable & Equatable>: ChildReactorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ReactorParentRef)?
    private let logic: TransitionReactorLogic<Context>
    private let input: SendableValue?
    private let syncSnapshot: Bool
    private let emitListeners = EmitListeners()
    private let lock = NSLock()
    private var context: Context
    private(set) var status: SnapshotStatus = .stopped

    var definitionJSON: String? { nil }

    init(
        id: String,
        systemId: String?,
        input: SendableValue?,
        parent: any ReactorParentRef,
        logic: TransitionReactorLogic<Context>,
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

    func start() {
        lock.lock()
        guard status == .stopped else {
            lock.unlock()
            return
        }
        status = .active
        context = logic.resolveInitialContext(input)
        let snapshotValue = String(describing: context)
        lock.unlock()

        if syncSnapshot {
            parent?.enqueueFromChild(
                SnapshotReactorEvent(
                    reactorId: id,
                    snapshot: ChildReactorSnapshot(
                        id: id,
                        status: .active,
                        value: snapshotValue
                    )
                )
            )
        }
    }

    func stop() {
        lock.lock()
        status = .stopped
        lock.unlock()
        emitListeners.removeAll()
    }

    func send(_ event: any Eventable) {
        lock.lock()
        guard status == .active else {
            lock.unlock()
            return
        }

        let scope = TransitionReactorScope(
            input: input,
            system: parent?.reactorSystem ?? ReactorSystem(),
            sendToParent: { [weak self] childEvent in
                self?.parent?.enqueueFromChild(childEvent)
            },
            emit: { [emitListeners] emitted in
                emitListeners.notify(emitted)
            }
        )
        context = logic.transition(context, event, scope)
        let snapshotValue = String(describing: context)
        lock.unlock()

        if syncSnapshot {
            parent?.enqueueFromChild(
                SnapshotReactorEvent(
                    reactorId: id,
                    snapshot: ChildReactorSnapshot(
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
    ) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }
}

/// Returns transition reactor logic with a fixed initial context.
public func fromTransition<Context: Sendable & Equatable>(
    _ transition: @escaping @Sendable (Context, any Eventable, TransitionReactorScope) -> Context,
    initialContext: Context
) -> ReactorSource {
    .transition(TransitionReactorLogicBox(TransitionReactorLogic(
        transition: transition,
        resolveInitialContext: { _ in initialContext }
    )))
}

/// Returns transition reactor logic with initial context derived from input.
public func fromTransition<Context: Sendable & Equatable>(
    _ transition: @escaping @Sendable (Context, any Eventable, TransitionReactorScope) -> Context,
    initialContext: @escaping @Sendable (SendableValue?) -> Context
) -> ReactorSource {
    .transition(TransitionReactorLogicBox(TransitionReactorLogic(
        transition: transition,
        resolveInitialContext: initialContext
    )))
}
