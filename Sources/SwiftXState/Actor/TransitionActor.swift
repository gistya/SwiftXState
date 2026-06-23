import Foundation

/// Scope passed to transition-based actor logic (`fromTransition`).
public struct TransitionActorScope {
    public let input: SendableValue?
    public let system: ActorSystem
    public let sendToParent: (any Eventable) -> Void
    public let emit: (EmittedEvent) -> Void

    public init(
        input: SendableValue?,
        system: ActorSystem,
        sendToParent: @escaping (any Eventable) -> Void,
        emit: @escaping (EmittedEvent) -> Void
    ) {
        self.input = input
        self.system = system
        self.sendToParent = sendToParent
        self.emit = emit
    }
}

/// Reducer-style actor logic, mirroring XState's `fromTransition`.
public struct TransitionActorLogic<Context: Sendable & Equatable>: Sendable {
    public let transition: @Sendable (Context, any Eventable, TransitionActorScope) -> Context
    public let resolveInitialContext: @Sendable (SendableValue?) -> Context

    public init(
        transition: @escaping @Sendable (Context, any Eventable, TransitionActorScope) -> Context,
        resolveInitialContext: @escaping @Sendable (SendableValue?) -> Context
    ) {
        self.transition = transition
        self.resolveInitialContext = resolveInitialContext
    }
}

/// Type-erased transition actor logic.
public struct TransitionActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?,
        Bool
    ) -> any ChildActorRef

    public init<Context: Sendable & Equatable>(_ logic: TransitionActorLogic<Context>) {
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
        parent: any ActorParentRef,
        systemId: String?,
        syncSnapshot: Bool
    ) -> any ChildActorRef {
        _spawn(id, input, parent, systemId, syncSnapshot)
    }
}

final class TransitionChildRef<Context: Sendable & Equatable>: ChildActorRef, @unchecked Sendable {
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

/// Returns transition actor logic with a fixed initial context.
public func fromTransition<Context: Sendable & Equatable>(
    _ transition: @escaping @Sendable (Context, any Eventable, TransitionActorScope) -> Context,
    initialContext: Context
) -> ActorSource {
    .transition(TransitionActorLogicBox(TransitionActorLogic(
        transition: transition,
        resolveInitialContext: { _ in initialContext }
    )))
}

/// Returns transition actor logic with initial context derived from input.
public func fromTransition<Context: Sendable & Equatable>(
    _ transition: @escaping @Sendable (Context, any Eventable, TransitionActorScope) -> Context,
    initialContext: @escaping @Sendable (SendableValue?) -> Context
) -> ActorSource {
    .transition(TransitionActorLogicBox(TransitionActorLogic(
        transition: transition,
        resolveInitialContext: initialContext
    )))
}
