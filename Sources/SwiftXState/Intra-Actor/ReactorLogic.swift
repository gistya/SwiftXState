import Foundation

/// Reference from a child reactor back to its parent interpreter.
public protocol ReactorParentRef: AnyObject, Sendable {
    func enqueueFromChild(_ event: any Eventable)
    var reactorSystem: ReactorSystem { get }
    func inspectSpawnedChild(_ child: any ChildReactorRef, machineId: String?)
    func persistedChildSnapshot(for id: String) -> PersistedChildSnapshot?
}

extension ReactorParentRef {
    public func persistedChildSnapshot(for id: String) -> PersistedChildSnapshot? {
        nil
    }
}

/// A running child reactor managed by a parent state machine reactor.
public protocol ChildReactorRef: ReactorSystemRef, AnyObject, Sendable {
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

extension ChildReactorRef {
    public var sessionId: String { id }
    public var errorMessage: String? { nil }
    public var machineId: String? { nil }
    public var snapshotValue: String? { nil }
    public var inspectable: Bool { true }
}

/// Source logic for spawning a child reactor.
public enum ReactorSource: Sendable {
    case named(String)
    case machine(MachineReactorLogicBox)
    case task(TaskReactorLogicBox)
    case callback(CallbackReactorLogicBox)
    case taskGroup(TaskGroupReactorLogicBox)
    case transition(TransitionReactorLogicBox)
    case observable(ObservableReactorLogicBox)
    case store(StoreReactorLogicBox)
}

/// Scope passed to task-based reactor logic (`fromTask`).
public struct TaskReactorScope: Sendable {
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

/// Scope passed to callback-based reactor logic (`fromCallback`).
public struct CallbackReactorScope: Sendable {
    public let input: SendableValue?
    public let sendToParent: @Sendable (any Eventable) -> Void
    public let receive: @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void
    public let emit: @Sendable (EmittedEvent) -> Void
    public let system: ReactorSystem

    public init(
        input: SendableValue?,
        sendToParent: @escaping @Sendable (any Eventable) -> Void,
        receive: @escaping @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void,
        emit: @escaping @Sendable (EmittedEvent) -> Void,
        system: ReactorSystem
    ) {
        self.input = input
        self.sendToParent = sendToParent
        self.receive = receive
        self.emit = emit
        self.system = system
    }

    /// Sends an event to the parent reactor. Matches XState's `sendBack(event)`.
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
public struct TaskReactorLogic<Output: Sendable & Equatable>: Sendable {
    public let run: @Sendable (TaskReactorScope) async throws -> Output
    public let onCancel: @Sendable (TaskReactorScope) async -> Void

    public init(
        run: @escaping @Sendable (TaskReactorScope) async throws -> Output,
        onCancel: (@Sendable (TaskReactorScope) async -> Void)? = nil
    ) {
        self.run = run
        self.onCancel = onCancel ?? { _ in }
    }
}

/// Callback logic for long-running listeners, mirroring XState's `fromCallback`.
public struct CallbackReactorLogic: Sendable {
    public let run: @Sendable (CallbackReactorScope) -> (@Sendable () -> Void)?

    public init(run: @escaping @Sendable (CallbackReactorScope) -> (@Sendable () -> Void)?) {
        self.run = run
    }
}

/// Task group logic for structured concurrent child work.
public struct TaskGroupReactorLogic<Output: Sendable & Equatable>: Sendable {
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

/// Type-erased machine reactor logic for child state machines.
public struct MachineReactorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ReactorParentRef,
        ReactorOptions,
        Bool,
        PersistedChildSnapshot?
    ) -> any ChildReactorRef

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
                reactor: Reactor(
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
            let reactor = Reactor(
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
                reactor: reactor,
                parent: parent,
                context: resolvedContext,
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore,
                onRestore: { persisted in reactor.start(from: persisted) }
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
                reactor: Reactor(
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
            let reactor = Reactor(
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
                reactor: reactor,
                parent: parent,
                context: context(input),
                syncSnapshot: syncSnapshot,
                persistedRestore: persistedRestore,
                onRestore: { persisted in reactor.start(from: persisted) }
            )
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ReactorParentRef,
        options: ReactorOptions,
        syncSnapshot: Bool,
        persistedChild: PersistedChildSnapshot? = nil
    ) -> any ChildReactorRef {
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

/// Type-erased task reactor logic.
public struct TaskReactorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ReactorParentRef,
        String?
    ) -> any ChildReactorRef

    public init<Output: Sendable & Equatable>(_ logic: TaskReactorLogic<Output>) {
        _spawn = { id, input, parent, systemId in
            TaskChildRef(id: id, systemId: systemId, input: input, parent: parent, logic: logic)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ReactorParentRef,
        systemId: String?
    ) -> any ChildReactorRef {
        _spawn(id, input, parent, systemId)
    }
}

/// Type-erased callback reactor logic.
public struct CallbackReactorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ReactorParentRef,
        ReactorSystem,
        String?
    ) -> any ChildReactorRef

    public init(_ logic: CallbackReactorLogic) {
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
        parent: any ReactorParentRef,
        system: ReactorSystem,
        systemId: String?
    ) -> any ChildReactorRef {
        _spawn(id, input, parent, system, systemId)
    }
}

/// Type-erased task group reactor logic.
public struct TaskGroupReactorLogicBox: Sendable {
    private let _spawn: @Sendable (
        String,
        SendableValue?,
        any ReactorParentRef,
        String?
    ) -> any ChildReactorRef

    public init<Output: Sendable & Equatable>(_ logic: TaskGroupReactorLogic<Output>) {
        _spawn = { id, input, parent, systemId in
            TaskGroupChildRef(id: id, systemId: systemId, input: input, parent: parent, logic: logic)
        }
    }

    func spawn(
        id: String,
        input: SendableValue?,
        parent: any ReactorParentRef,
        systemId: String?
    ) -> any ChildReactorRef {
        _spawn(id, input, parent, systemId)
    }
}

/// Reactor logic backed by an `async` task — XState's `fromPromise`. The returned `Output` becomes
/// the child's `done` data (drives `onDone`); throwing drives `onError`; `onCancel` runs if the
/// invoking state exits first. Use as an `invoke` `src` or with `spawnChild`.
public func fromTask<Output: Sendable & Equatable>(
    _ run: @escaping @Sendable (TaskReactorScope) async throws -> Output,
    onCancel: (@Sendable (TaskReactorScope) async -> Void)? = nil
) -> ReactorSource {
    .task(TaskReactorLogicBox(TaskReactorLogic(run: run, onCancel: onCancel)))
}

/// `fromTask` with the `onCancel` handler supplied first (trailing-closure ergonomics).
public func fromTask<Output: Sendable & Equatable>(
    onCancel: @escaping @Sendable (TaskReactorScope) async -> Void,
    _ run: @escaping @Sendable (TaskReactorScope) async throws -> Output
) -> ReactorSource {
    fromTask(run, onCancel: onCancel)
}

/// Reactor logic backed by a long-lived callback — XState's `fromCallback`. `run` receives a scope
/// to `send` events back to the parent and returns an optional cleanup closure run on stop.
public func fromCallback(
    _ run: @escaping @Sendable (CallbackReactorScope) -> (@Sendable () -> Void)?
) -> ReactorSource {
    .callback(CallbackReactorLogicBox(CallbackReactorLogic(run: run)))
}

public func fromTaskGroup<Output: Sendable & Equatable>(
    _ run: @escaping @Sendable (TaskGroupScope) async throws -> [Output],
    onCancel: (@Sendable (TaskGroupScope) async -> Void)? = nil
) -> ReactorSource {
    .taskGroup(TaskGroupReactorLogicBox(TaskGroupReactorLogic(run: run, onCancel: onCancel)))
}

public func fromTaskGroup<Output: Sendable & Equatable>(
    onCancel: @escaping @Sendable (TaskGroupScope) async -> Void,
    _ run: @escaping @Sendable (TaskGroupScope) async throws -> [Output]
) -> ReactorSource {
    fromTaskGroup(run, onCancel: onCancel)
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: StateMachine<ChildContext>
) -> ReactorSource {
    .machine(MachineReactorLogicBox(machine))
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: StateMachine<ChildContext>,
    context: @escaping @Sendable (SendableValue?) -> ChildContext
) -> ReactorSource {
    .machine(MachineReactorLogicBox(machine, context: context))
}

public func fromMachine<ChildContext: Sendable>(
    _ machine: StateMachine<ChildContext>,
    context: ChildContext
) -> ReactorSource {
    .machine(MachineReactorLogicBox(machine, context: { _ in context }))
}
