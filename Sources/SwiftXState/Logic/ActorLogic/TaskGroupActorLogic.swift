/// Task group logic for structured concurrent child work.
public struct TaskGroupActorLogic<Output: Sendable & Equatable>: Sendable {
    public let run: @Sendable (TaskGroupScope) async throws -> [Output]
    public let onCancel: @Sendable (TaskGroupScope) async -> Void

    public init(
        run: @escaping @Sendable (TaskGroupScope) async throws -> [Output],
        onCancel: (@Sendable (TaskGroupScope) async -> Void)? = nil
    ) {
        self.run = run
        self.onCancel = onCancel ?? { _ in }
    }
}

/// Type-erased task group actor logic.
public struct TaskGroupActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ParentActorRepresentable,
        String?
    ) -> any ChildActorRepresentable

    public init<Output: Sendable & Equatable>(_ logic: TaskGroupActorLogic<Output>) {
        _spawn = { id, input, parent, systemId in
            let actor = Actor(
                TaskGroupLogic(logic: logic),
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
        systemId: String?
    ) -> any ChildActorRepresentable {
        _spawn(id, input, parent, systemId)
    }
}
