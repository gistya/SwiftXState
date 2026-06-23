final class TaskChildRef<Output: Sendable & Equatable>: ChildActorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: TaskActorLogic<Output>
    private let input: SendableValue?
    private let emitListeners = EmitListeners()
    private let parentDeliveries = ParentDeliveryChain()
    private var task: Task<Void, Never>?
    private var cleanup: AsyncCancelCleanup?
    private(set) var status: SnapshotStatus = .stopped
    private(set) var lastError: String?

    var errorMessage: String? { lastError }
    var definitionJSON: String? { nil }

    init(
        id: String,
        systemId: String?,
        input: SendableValue?,
        parent: any ActorParentRef,
        logic: TaskActorLogic<Output>
    ) {
        self.id = id
        self.systemId = systemId
        self.input = input
        self.parent = parent
        self.logic = logic
    }

    func start() async {
        guard task == nil else { return }
        status = .active
        lastError = nil

        let scope = makeScope()
        let logic = self.logic
        let cleanup = AsyncCancelCleanup(onCancel: { await logic.onCancel(scope) })
        self.cleanup = cleanup

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await runAsyncChildLogic(
                    cleanup: cleanup,
                    operation: { try await logic.run(scope) }
                )
                guard !Task.isCancelled else { return }
                status = .done
                // Deliver done on the same chain as `sendToParent`, so an event the task sent just
                // before returning is enqueued (and processed) ahead of this done event.
                parentDeliveries.deliver(to: parent, DoneActorEvent(actorId: id, output: SendableValue(output)))
                await parentDeliveries.drain()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = String(describing: error)
                status = .error
                lastError = message
                parentDeliveries.deliver(to: parent, ErrorActorEvent(actorId: id, error: message))
                await parentDeliveries.drain()
            }
        }
    }

    func stop() async {
        task?.cancel()
        cleanup?.schedule()
        task = nil
        cleanup = nil
        status = .stopped
        lastError = nil
        emitListeners.removeAll()
    }

    private func makeScope() -> TaskActorScope {
        TaskActorScope(
            input: input,
            sendToParent: { [weak self] event in
                guard let self else { return }
                self.parentDeliveries.deliver(to: self.parent, event)
            },
            emit: { [emitListeners] event in
                emitListeners.notify(event)
            }
        )
    }

    func send(_: any Eventable) async {}

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }
}

extension TaskChildRef: PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot? {
        guard status != .stopped else { return nil }
        return .opaque(
            PersistedOpaqueChildSnapshot(status: status, error: lastError)
        )
    }
}
