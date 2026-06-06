import Foundation

/// Reference from a child actor back to its parent interpreter.
public protocol ActorParentRef: AnyObject, Sendable {
    func enqueueFromChild(_ event: any Eventable)
    var actorSystem: ActorSystem { get }
    func inspectSpawnedChild(_ child: any ChildActorRef, machineId: String?)
    func persistedChildSnapshot(for id: String) -> PersistedChildSnapshot?
}

extension ActorParentRef {
    public func persistedChildSnapshot(for id: String) -> PersistedChildSnapshot? {
        nil
    }
}

/// A running child actor managed by a parent state machine actor.
public protocol ChildActorRef: ActorSystemRef, AnyObject, Sendable {
    var id: String { get }
    var status: SnapshotStatus { get }
    var errorMessage: String? { get }
    var machineId: String? { get }
    var definitionJSON: String? { get }
    /// Whether Stately Inspector should receive events attributed to this child.
    var inspectable: Bool { get }
    func start()
    func stop()
    func send(_ event: any Eventable)
    func on(_ eventType: String, handler: @escaping @Sendable (EmittedEvent) -> Void) -> Subscription
}

extension ChildActorRef {
    public var sessionId: String { id }
    public var errorMessage: String? { nil }
    public var machineId: String? { nil }
    public var snapshotValue: String? { nil }
    public var inspectable: Bool { true }
}

/// Source logic for spawning a child actor.
public enum ActorSource: Sendable {
    case named(String)
    case machine(MachineActorLogicBox)
    case task(TaskActorLogicBox)
    case callback(CallbackActorLogicBox)
    case taskGroup(TaskGroupActorLogicBox)
    case transition(TransitionActorLogicBox)
    case observable(ObservableActorLogicBox)
    case store(StoreActorLogicBox)
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

/// Scope passed to callback-based actor logic (`fromCallback`).
public struct CallbackActorScope: Sendable {
    public let input: SendableValue?
    public let sendToParent: @Sendable (any Eventable) -> Void
    public let receive: @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void
    public let emit: @Sendable (EmittedEvent) -> Void
    public let system: ActorSystem

    public init(
        input: SendableValue?,
        sendToParent: @escaping @Sendable (any Eventable) -> Void,
        receive: @escaping @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void,
        emit: @escaping @Sendable (EmittedEvent) -> Void,
        system: ActorSystem
    ) {
        self.input = input
        self.sendToParent = sendToParent
        self.receive = receive
        self.emit = emit
        self.system = system
    }

    /// Sends an event to the parent actor. Matches XState's `sendBack(event)`.
    ///
    /// Accepts any `Eventable`, including `Event("TYPE")` and string literals (`"TYPE"`).
    public var sendBack: @Sendable (any Eventable) -> Void {
        sendToParent
    }
}

/// Scope for running multiple async operations via `TaskGroup`.
public struct TaskGroupScope: Sendable {
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

    /// Runs operations concurrently and collects results in completion order.
    /// Respects task cancellation between operations and while collecting results.
    public func runGroup<Output: Sendable & Equatable>(
        _ operations: [@Sendable () async throws -> Output]
    ) async throws -> [Output] {
        try await withThrowingTaskGroup(of: Output.self) { group in
            for operation in operations {
                try Task.checkCancellation()
                group.addTask {
                    try await operation()
                }
            }
            var results: [Output] = []
            for try await result in group {
                try Task.checkCancellation()
                results.append(result)
            }
            return results
        }
    }
}

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

/// Callback logic for long-running listeners, mirroring XState's `fromCallback`.
public struct CallbackActorLogic: Sendable {
    public let run: @Sendable (CallbackActorScope) -> (@Sendable () -> Void)?

    public init(run: @escaping @Sendable (CallbackActorScope) -> (@Sendable () -> Void)?) {
        self.run = run
    }
}

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

/// Type-erased machine actor logic for child state machines.
public struct MachineActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        ActorOptions,
        Bool,
        PersistedChildSnapshot?
    ) -> any ChildActorRef

    /// Uses the child machine's `context` or `contextFromInput` to build initial context.
    public init<ChildContext: Sendable>(_ machine: StateMachine<ChildContext>) {
        _spawn = { id, input, parent, options, syncSnapshot, persistedChild in
            let resolvedContext = resolveInitialContext(machine: machine, input: input)
            let persistedRestore = machinePersistedRestore(
                from: persistedChild,
                childId: id,
                machineId: machine.id
            )
            return MachineChildRef(
                actor: Actor(
                    machine,
                    id: id,
                    options: options,
                    parent: parent
                ),
                parent: parent,
                context: resolvedContext,
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore
            )
        }
    }

    /// Uses the child machine's `context` or `contextFromInput` to build initial context.
    /// Child snapshots can be persisted and restored when `ChildContext` is `Codable`.
    public init<ChildContext: Codable & Sendable>(_ machine: StateMachine<ChildContext>) {
        _spawn = { id, input, parent, options, syncSnapshot, persistedChild in
            let actor = Actor(
                machine,
                id: id,
                options: options,
                parent: parent
            )
            let resolvedContext = resolveInitialContext(machine: machine, input: input)
            let persistedRestore = machinePersistedRestore(
                from: persistedChild,
                childId: id,
                machineId: machine.id
            )
            return MachineChildRef(
                actor: actor,
                parent: parent,
                context: resolvedContext,
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore,
                onRestore: { persisted in actor.start(from: persisted) }
            )
        }
    }

    public init<ChildContext: Sendable>(
        _ machine: StateMachine<ChildContext>,
        context: @escaping @Sendable (SendableValue?) -> ChildContext
    ) {
        _spawn = { id, input, parent, options, syncSnapshot, persistedChild in
            let persistedRestore = machinePersistedRestore(
                from: persistedChild,
                childId: id,
                machineId: machine.id
            )
            return MachineChildRef(
                actor: Actor(
                    machine,
                    id: id,
                    options: options,
                    parent: parent
                ),
                parent: parent,
                context: context(input),
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore
            )
        }
    }

    public init<ChildContext: Codable & Sendable>(
        _ machine: StateMachine<ChildContext>,
        context: @escaping @Sendable (SendableValue?) -> ChildContext
    ) {
        _spawn = { id, input, parent, options, syncSnapshot, persistedChild in
            let actor = Actor(
                machine,
                id: id,
                options: options,
                parent: parent
            )
            let persistedRestore = machinePersistedRestore(
                from: persistedChild,
                childId: id,
                machineId: machine.id
            )
            return MachineChildRef(
                actor: actor,
                parent: parent,
                context: context(input),
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore,
                onRestore: { persisted in actor.start(from: persisted) }
            )
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        options: ActorOptions,
        syncSnapshot: Bool,
        persistedChild: PersistedChildSnapshot? = nil
    ) -> any ChildActorRef {
        _spawn(id, input, parent, options, syncSnapshot, persistedChild)
    }
}

private func machinePersistedRestore(
    from persistedChild: PersistedChildSnapshot?,
    childId: String,
    machineId: String
) -> PersistedSnapshot? {
    guard let persistedChild else { return nil }
    if case let .machine(snapshot) = persistedChild {
        if snapshot.machineId != machineId {
            let error = PersistenceError.childMachineMismatch(
                childId: childId,
                expected: snapshot.machineId,
                actual: machineId
            )
            fatalError("\(error)")
        }
        return snapshot
    }
    return nil
}

/// Type-erased task actor logic.
public struct TaskActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?
    ) -> any ChildActorRef

    public init<Output: Sendable & Equatable>(_ logic: TaskActorLogic<Output>) {
        _spawn = { id, input, parent, systemId in
            TaskChildRef(id: id, systemId: systemId, input: input, parent: parent, logic: logic)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        systemId: String?
    ) -> any ChildActorRef {
        _spawn(id, input, parent, systemId)
    }
}

/// Type-erased callback actor logic.
public struct CallbackActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        ActorSystem,
        String?
    ) -> any ChildActorRef

    public init(_ logic: CallbackActorLogic) {
        _spawn = { id, input, parent, system, systemId in
            CallbackChildRef(
                id: id,
                systemId: systemId,
                input: input,
                parent: parent,
                logic: logic,
                system: system
            )
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        system: ActorSystem,
        systemId: String?
    ) -> any ChildActorRef {
        _spawn(id, input, parent, system, systemId)
    }
}

/// Type-erased task group actor logic.
public struct TaskGroupActorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ActorParentRef,
        String?
    ) -> any ChildActorRef

    public init<Output: Sendable & Equatable>(_ logic: TaskGroupActorLogic<Output>) {
        _spawn = { id, input, parent, systemId in
            TaskGroupChildRef(id: id, systemId: systemId, input: input, parent: parent, logic: logic)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ActorParentRef,
        systemId: String?
    ) -> any ChildActorRef {
        _spawn(id, input, parent, systemId)
    }
}

/// Actor logic backed by an `async` task — XState's `fromPromise`. The returned `Output` becomes
/// the child's `done` data (drives `onDone`); throwing drives `onError`; `onCancel` runs if the
/// invoking state exits first. Use as an `invoke` `src` or with `spawnChild`.
public func fromTask<Output: Sendable & Equatable>(
    _ run: @escaping @Sendable (TaskActorScope) async throws -> Output,
    onCancel: (@Sendable (TaskActorScope) async -> Void)? = nil
) -> ActorSource {
    .task(TaskActorLogicBox(TaskActorLogic(run: run, onCancel: onCancel)))
}

/// `fromTask` with the `onCancel` handler supplied first (trailing-closure ergonomics).
public func fromTask<Output: Sendable & Equatable>(
    onCancel: @escaping @Sendable (TaskActorScope) async -> Void,
    _ run: @escaping @Sendable (TaskActorScope) async throws -> Output
) -> ActorSource {
    fromTask(run, onCancel: onCancel)
}

/// Actor logic backed by a long-lived callback — XState's `fromCallback`. `run` receives a scope
/// to `send` events back to the parent and returns an optional cleanup closure run on stop.
public func fromCallback(
    _ run: @escaping @Sendable (CallbackActorScope) -> (@Sendable () -> Void)?
) -> ActorSource {
    .callback(CallbackActorLogicBox(CallbackActorLogic(run: run)))
}

public func fromTaskGroup<Output: Sendable & Equatable>(
    _ run: @escaping @Sendable (TaskGroupScope) async throws -> [Output],
    onCancel: (@Sendable (TaskGroupScope) async -> Void)? = nil
) -> ActorSource {
    .taskGroup(TaskGroupActorLogicBox(TaskGroupActorLogic(run: run, onCancel: onCancel)))
}

public func fromTaskGroup<Output: Sendable & Equatable>(
    onCancel: @escaping @Sendable (TaskGroupScope) async -> Void,
    _ run: @escaping @Sendable (TaskGroupScope) async throws -> [Output]
) -> ActorSource {
    fromTaskGroup(run, onCancel: onCancel)
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: StateMachine<ChildContext>
) -> ActorSource {
    .machine(MachineActorLogicBox(machine))
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: StateMachine<ChildContext>,
    context: @escaping @Sendable (SendableValue?) -> ChildContext
) -> ActorSource {
    .machine(MachineActorLogicBox(machine, context: context))
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: StateMachine<ChildContext>,
    context: ChildContext
) -> ActorSource {
    .machine(MachineActorLogicBox(machine, context: { _ in context }))
}
