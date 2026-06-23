import Foundation

/// Serializes a child's deliveries to its parent. Each delivery awaits the previous one, so the
/// events a child sends keep their order — and, crucially, a `DoneActorEvent`/`ErrorActorEvent`
/// enqueued right after the child's work finishes lands *after* any event the work sent just before
/// returning. (Without this, the deliveries are detached tasks that race, so the parent can transition
/// on the done event before it ever processes the earlier `sendToParent`.)
final class ParentDeliveryChain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func deliver(to parent: (any ActorParentRef)?, _ event: any Eventable) {
        lock.lock()
        let previous = tail
        tail = Task { [weak parent] in
            await previous?.value
            await parent?.enqueueFromChild(event)
        }
        lock.unlock()
    }

    /// Waits until everything queued so far has been enqueued to the parent.
    func drain() async {
        let task = lock.withLock { tail }
        await task?.value
    }
}

protocol PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot?
}

func collectPersistedChildSnapshots(
    from children: [String: any ChildActorRef]
) async throws -> [String: PersistedChildSnapshot] {
    var result: [String: PersistedChildSnapshot] = [:]
    for (id, child) in children {
        guard let provider = child as? any PersistedChildSnapshotProviding else { continue }
        if let snapshot = try await provider.makePersistedChildSnapshot() {
            result[id] = snapshot
        }
    }
    return result
}

final class MachineChildRef<ChildContext: Sendable>: ChildActorRef, @unchecked Sendable {
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

final class TaskGroupChildRef<Output: Sendable & Equatable>: ChildActorRef, @unchecked Sendable {
    let id: String
    let systemId: String?
    private weak var parent: (any ActorParentRef)?
    private let logic: TaskGroupActorLogic<Output>
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
        logic: TaskGroupActorLogic<Output>
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
                let outputs = try await runAsyncChildLogic(
                    cleanup: cleanup,
                    operation: { try await logic.run(scope) }
                )
                guard !Task.isCancelled else { return }
                status = .done
                parentDeliveries.deliver(to: parent, DoneActorEvent(actorId: id, output: SendableValue(outputs)))
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

    private func makeScope() -> TaskGroupScope {
        TaskGroupScope(
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

extension TaskGroupChildRef: PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot? {
        guard status != .stopped else { return nil }
        return .opaque(
            PersistedOpaqueChildSnapshot(status: status, error: lastError)
        )
    }
}
