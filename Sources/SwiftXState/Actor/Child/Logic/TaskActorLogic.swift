/// Async task logic, mirroring XState's `fromPromise`.
public struct TaskActorLogic<Output: Sendable & Equatable>: Sendable {
    public let run: @Sendable (TaskActorScope) async throws -> Output
    public let onCancel: @Sendable (TaskActorScope) async -> Void

    public init(
        run: @escaping @Sendable (TaskActorScope) async throws -> Output,
        onCancel: (@Sendable (TaskActorScope) async -> Void)? = nil
    ) {
        self.run = run
        self.onCancel = onCancel ?? { _ in }
    }
}

/// Type-erased task actor logic.
public struct TaskActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?
    ) -> any ChildActor

    public init<Output: Sendable & Equatable>(_ logic: TaskActorLogic<Output>) {
        _spawn = { id, input, parent, systemId in
            let actor = LogicActor(
                TaskLogic(logic: logic),
                id: id,
                options: ActorOptions(systemId: systemId),
                parent: parent,
                system: parent.actorSystem
            )
            return LogicChildActor(actor: actor, id: id, systemId: systemId, input: input, inspectable: true)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        systemId: String?
    ) -> any ChildActor {
        _spawn(id, input, parent, systemId)
    }
}

/// Scope passed to task-based actor logic (`fromTask`).
public struct TaskActorScope: Sendable {
    public let input: SendableValue?
    public let sendToParent: @Sendable (any Eventable) -> Void
    public let emit: @Sendable (EmittedEvent) -> Void

    public init(
        input: SendableValue?,
        sendToParent: @escaping @Sendable (any Eventable) -> Void,
        emit: @escaping @Sendable (EmittedEvent) -> Void
    ) {
        self.input = input
        self.sendToParent = sendToParent
        self.emit = emit
    }
}
