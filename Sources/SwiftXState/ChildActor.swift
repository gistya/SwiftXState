import Foundation

protocol PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() throws -> PersistedChildSnapshot?
}

func collectPersistedChildSnapshots(
    from children: [String: any ChildActorRef]
) throws -> [String: PersistedChildSnapshot] {
    var result: [String: PersistedChildSnapshot] = [:]
    for (id, child) in children {
        guard let provider = child as? any PersistedChildSnapshotProviding else { continue }
        if let snapshot = try provider.makePersistedChildSnapshot() {
            result[id] = snapshot
        }
    }
    return result
}

final class MachineChildRef<ChildContext: Sendable>: ChildActorRef, @unchecked Sendable {
    let actor: Actor<ChildContext>
    private weak var parent: (any ActorParentRef)?
    private var subscription: Subscription?
    private var doneSent = false
    private let initialContext: ChildContext
    private let syncSnapshot: Bool
    private let persistedRestore: PersistedSnapshot?
    private let onRestore: (@Sendable (PersistedSnapshot) -> Void)?

    var id: String { actor.id }
    var systemId: String? { actor.systemId }
    var inspectable: Bool { actor.isInspectable }
    var machineId: String? { actor.machine.id }
    var definitionJSON: String? { try? actor.machine.definitionJSON() }
    var snapshotValue: String? { actor.snapshot.value.description }

    var status: SnapshotStatus {
        actor.status
    }

    init(
        actor: Actor<ChildContext>,
        parent: any ActorParentRef,
        context: ChildContext,
        syncSnapshot: Bool = false,
        persistedRestore: PersistedSnapshot? = nil,
        onRestore: (@Sendable (PersistedSnapshot) -> Void)? = nil
    ) {
        self.actor = actor
        self.parent = parent
        self.initialContext = context
        self.syncSnapshot = syncSnapshot
        self.persistedRestore = persistedRestore
        self.onRestore = onRestore
    }

    func start() {
        if let persistedRestore, let onRestore {
            onRestore(persistedRestore)
            if persistedRestore.status == .done {
                doneSent = true
            }
        } else {
            actor.start(context: initialContext)
        }
        subscription = actor.subscribe { [weak self] snapshot in
            guard let self else { return }

            if syncSnapshot, snapshot.status == .active {
                parent?.enqueueFromChild(
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

            guard !doneSent, snapshot.status == .done else { return }
            doneSent = true
            parent?.enqueueFromChild(
                DoneActorEvent(
                    actorId: id,
                    output: snapshot.output
                )
            )
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        actor.stop()
    }

    func send(_ event: any Eventable) {
        actor.send(event)
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        actor.on(eventType, handler: handler)
    }
}

extension MachineChildRef: PersistedChildSnapshotProviding where ChildContext: Codable {
    func makePersistedChildSnapshot() throws -> PersistedChildSnapshot? {
        .machine(try actor.getPersistedSnapshot())
    }
}

final class TaskChildRef<Output: Sendable & Equatable>: ChildActorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: TaskActorLogic<Output>
    private let input: SendableValue?
    private let emitListeners = EmitListeners()
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

    func start() {
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
                parent?.enqueueFromChild(
                    DoneActorEvent(actorId: id, output: SendableValue(output))
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = String(describing: error)
                status = .error
                lastError = message
                parent?.enqueueFromChild(
                    ErrorActorEvent(actorId: id, error: message)
                )
            }
        }
    }

    func stop() {
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
                self?.parent?.enqueueFromChild(event)
            },
            emit: { [emitListeners] event in
                emitListeners.notify(event)
            }
        )
    }

    func send(_: any Eventable) {}

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }
}

extension TaskChildRef: PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() throws -> PersistedChildSnapshot? {
        guard status != .stopped else { return nil }
        return .opaque(
            PersistedOpaqueChildSnapshot(status: status, error: lastError)
        )
    }
}

final class CallbackChildRef: ChildActorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: CallbackActorLogic
    private let input: SendableValue?
    private let system: ActorSystem
    private let emitListeners = EmitListeners()
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

    func start() {
        guard dispose == nil else { return }
        status = .active

        let scope = CallbackActorScope(
            input: input,
            sendToParent: { [weak self] event in
                self?.parent?.enqueueFromChild(event)
            },
            receive: { [weak self] listener in
                self?.lock.lock()
                self?.receivers.append(listener)
                self?.lock.unlock()
            },
            emit: { [emitListeners] event in
                emitListeners.notify(event)
            },
            system: system
        )

        dispose = logic.run(scope)
    }

    func stop() {
        dispose?()
        dispose = nil
        lock.lock()
        receivers.removeAll()
        lock.unlock()
        status = .stopped
        emitListeners.removeAll()
    }

    func send(_ event: any Eventable) {
        lock.lock()
        let listeners = receivers
        lock.unlock()
        for listener in listeners {
            listener(event)
        }
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }
}

extension CallbackChildRef: PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() throws -> PersistedChildSnapshot? {
        guard status != .stopped else { return nil }
        return .opaque(PersistedOpaqueChildSnapshot(status: status))
    }
}

final class TaskGroupChildRef<Output: Sendable & Equatable>: ChildActorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: TaskGroupActorLogic<Output>
    private let input: SendableValue?
    private let emitListeners = EmitListeners()
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
        logic: TaskGroupActorLogic<Output>
    ) {
        self.id = id
        self.systemId = systemId
        self.input = input
        self.parent = parent
        self.logic = logic
    }

    func start() {
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
                let outputs = try await runAsyncChildLogic(
                    cleanup: cleanup,
                    operation: { try await logic.run(scope) }
                )
                guard !Task.isCancelled else { return }
                status = .done
                parent?.enqueueFromChild(
                    DoneActorEvent(actorId: id, output: SendableValue(outputs))
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = String(describing: error)
                status = .error
                lastError = message
                parent?.enqueueFromChild(
                    ErrorActorEvent(actorId: id, error: message)
                )
            }
        }
    }

    func stop() {
        task?.cancel()
        cleanup?.schedule()
        task = nil
        cleanup = nil
        status = .stopped
        lastError = nil
        emitListeners.removeAll()
    }

    private func makeScope() -> TaskGroupScope {
        TaskGroupScope(
            input: input,
            sendToParent: { [weak self] event in
                self?.parent?.enqueueFromChild(event)
            },
            emit: { [emitListeners] event in
                emitListeners.notify(event)
            }
        )
    }

    func send(_: any Eventable) {}

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }
}

extension TaskGroupChildRef: PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() throws -> PersistedChildSnapshot? {
        guard status != .stopped else { return nil }
        return .opaque(
            PersistedOpaqueChildSnapshot(status: status, error: lastError)
        )
    }
}