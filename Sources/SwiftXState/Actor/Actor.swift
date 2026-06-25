import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// The Context-agnostic runtime resources an effectful `ActorLogic` needs from its host actor while
/// handling an event — timers, children, parent/system wiring, emit. Because `Actor` provides
/// this and `ActorLogic.handle` takes the host as an **`isolated`** parameter, an effectful logic
/// (`MachineLogic`) runs its side-effect dispatch / `after` / `invoke` *inside the actor's isolation*
/// with no hops, exactly as `StateActor` does inline — but without the actor needing to know the
/// logic's `Context`. All the Context-specific work (the action switch, `makeChildActor`) lives in
/// the logic; the host only exposes these non-generic primitives.
public protocol MachineHost: _Concurrency.Actor, ActorParentRef, ActorSystemRef {
    var childRegistry: ChildRegistry { get }
    var hostClock: any Clock { get }
    func emit(_ event: EmittedEvent)
    func deliverToChild(id childId: String, event: any Eventable) async
    func enqueueToParent(_ event: any Eventable) async
    /// Synchronously enqueue an event to the parent on the ordered delivery chain (for reducer-style
    /// children like `fromTransition`, whose scope `sendToParent` is synchronous).
    func sendToParentOrdered(_ event: any Eventable)
    func scheduleSelfEvent(timerId: String, delay: Int, event: Event)
    func scheduleChildEvent(timerId: String, delay: Int, childId: String, event: Event)
    func cancelTimer(_ timerId: String)
    func registerChild(_ child: any ChildActor)
    func unregisterChild(_ child: any ChildActor)
    /// The persisted snapshot to seed a child with during restore (nil in normal operation).
    func pendingChildSnapshot(_ id: String) -> PersistedChildSnapshot?

    // Inspection primitives, so an effectful logic can emit `.microstep` / `.action` events as it
    // runs. `emitInspection` keeps the `@autoclosure` guard (no Mirror-encode without an inspector).
    var inspectionActorRef: InspectionActorRef { get }
    var inspectionRootId: String { get }
    var recordsMicrosteps: Bool { get }
    func emitInspection(_ event: @autoclosure () -> InspectionEvent?)
}

/// **Experimental — generics refactor.** The generic actor *core*: a mailbox + run-to-completion
/// loop + observers, parameterized purely by an `ActorLogic`. It folds events into snapshots via the
/// logic and notifies subscribers, owning no `Context` itself.
///
/// It also owns the Context-agnostic runtime resources (timer scheduler, child registry, actor
/// system, parent) and conforms to `MachineHost`, so an *effectful* logic can run side effects /
/// `after` / `invoke` through it. With that, one `Actor<L>` provably hosts every logic shape:
/// hand-written reducers, runnables (callback/task/observable), and full state machines —
/// `Actor<MachineLogic<C>>` reaches parity with `Actor`. See `LogicActorTests`.
public actor Actor<L: ActorLogic>: ActorParentRef, ActorSystemRef, MachineHost {
    /// The logic this actor runs. `var` (not `let`) only so the machine convenience `start(context:)`
    /// can rebuild it with a context override before the initial transition; otherwise immutable.
    var logic: L
    private var _snapshot: L.Snapshot?
    private var mailbox: [any Eventable] = []
    private var isProcessing = false
    private var observers: [(id: Int, handler: @Sendable (L.Snapshot) -> Void)] = []
    private var nextObserverID = 0
    private var runTask: Task<Void, Never>?
    // Runnable-logic (callback/task/observable) support: incoming-event receivers (lock-boxed so a
    // background `run` can register without a racing hop), the run's cleanup, and one serial chain
    // for outbound parent deliveries (so `sendToParent` keeps order centrally — the XState-v6 lesson,
    // no per-child ParentDeliveryChain).
    private nonisolated let receivers = ReceiverBox()
    private var runCleanup: (@Sendable () -> Void)?
    private nonisolated let parentDeliveries = ParentDeliveryChain()
    // Terminal status for completing children (task/observable/transition/store) set via the scope's
    // complete/fail; overrides the snapshot-derived status. `statusObservers` lets the ChildActor
    // adapter cache status changes.
    private var terminalStatus: SnapshotStatus?
    private var lastError: String?
    // For machine children: emit a SnapshotActorEvent per active snapshot, and one Done/Error event
    // when the snapshot itself reaches a terminal state (final). Gated on having a parent.
    private nonisolated let childSyncSnapshot: Bool
    private var childDoneSent = false
    private var statusObservers: [(id: Int, handler: @Sendable (SnapshotStatus, String?) -> Void)] = []

    private let emitListeners = EmitListeners()
    public let childRegistry = ChildRegistry()
    /// Persisted child snapshots awaiting re-spawn during `start(from:)`; empty otherwise.
    private var pendingChildSnapshots: [String: PersistedChildSnapshot] = [:]
    private let scheduler: DelayScheduler
    private weak var parent: (any ActorParentRef)?
    private nonisolated let system: ActorSystem
    private nonisolated let options: ActorOptions
    private nonisolated let clock: any Clock
    private nonisolated let inspectable: Bool

    public nonisolated let id: String

    #if canImport(Darwin)
    // Custom executor backing, matching Actor: `ActorOptions.useMainExecutor` runs on the MainActor's
    // serial executor (no thread hop from the main actor, for SwiftUI); otherwise a dedicated serial
    // queue preserves off-main serialization. `ownedExecutorQueue` retains the queue for the actor's
    // lifetime (an `UnownedSerialExecutor` does not retain).
    private nonisolated let ownedExecutorQueue: DispatchSerialQueue?
    private nonisolated let _unownedExecutor: UnownedSerialExecutor

    public nonisolated var unownedExecutor: UnownedSerialExecutor { _unownedExecutor }
    #endif

    public nonisolated var actorSystem: ActorSystem { system }
    public nonisolated var sessionId: String { id }
    public nonisolated var systemId: String? { options.systemId }
    public nonisolated var hostClock: any Clock { clock }

    public init(
        _ logic: L,
        id: String = UUID().uuidString,
        options: ActorOptions = ActorOptions(),
        parent: (any ActorParentRef)? = nil,
        system: ActorSystem? = nil,
        syncSnapshot: Bool = false
    ) {
        self.logic = logic
        self.id = id
        self.options = options
        self.childSyncSnapshot = syncSnapshot
        self.clock = options.clock
        self.inspectable = options.inspectable
        self.scheduler = DelayScheduler(clock: options.clock)
        #if canImport(Darwin)
        if options.useMainExecutor {
            self.ownedExecutorQueue = nil
            self._unownedExecutor = MainActor.sharedUnownedExecutor
        } else {
            let queue = DispatchSerialQueue(label: "SwiftXState.Actor")
            self.ownedExecutorQueue = queue
            self._unownedExecutor = queue.asUnownedSerialExecutor()
        }
        #endif
        self.parent = parent
        self.system = system ?? parent?.actorSystem ?? ActorSystem()
        if parent == nil {
            self.system.setRootIdIfNeeded(id)
        }
        if inspectable, let inspect = options.inspect {
            self.system.inspect(inspect)
        }
    }

    public var inspectionActorRef: InspectionActorRef {
        InspectionActorRef.from(self, machineId: logic.inspectionMachineId())
    }

    public var inspectionRootId: String {
        system.rootSessionId ?? id
    }

    /// Whether intermediate microstep snapshots are recorded (and thus inspectable). We only need
    /// them when an inspector may be attached, so gate on `inspectable`.
    public var recordsMicrosteps: Bool { inspectable }

    /// `event` is an `@autoclosure` so the (potentially expensive) `InspectionEvent` — which
    /// `Mirror`-encodes the whole `Context` — is only built when an inspector is actually attached,
    /// exactly as in `Actor`. A nil result (a non-inspected logic) emits nothing.
    public func emitInspection(_ event: @autoclosure () -> InspectionEvent?) {
        guard inspectable, system.hasInspectors else { return }
        if let event = event() { system.sendInspection(event) }
    }

    /// The current snapshot. Traps if the actor hasn't been started.
    public var snapshot: L.Snapshot {
        guard let snapshot = _snapshot else {
            fatalError("Actor has not been started. Call start() first.")
        }
        return snapshot
    }

    public var status: SnapshotStatus {
        if let terminalStatus { return terminalStatus }
        guard let snapshot = _snapshot else { return .stopped }
        return logic.status(of: snapshot)
    }

    /// The last error message (set by `fail`), for `ChildActor.errorMessage`.
    var errorMessage: String? { lastError }

    /// Observe status changes (snapshot-derived or terminal). Used by the `ChildActor` adapter to
    /// cache status synchronously. Fires immediately with the current status.
    @discardableResult
    func subscribeStatus(_ handler: @escaping @Sendable (SnapshotStatus, String?) -> Void) -> Subscription {
        handler(status, lastError)
        let id = nextObserverID
        nextObserverID += 1
        statusObservers.append((id: id, handler: handler))
        return Subscription { [weak self] in
            Task { await self?.removeStatusObserver(id: id) }
        }
    }

    private func removeStatusObserver(id: Int) {
        statusObservers.removeAll { $0.id == id }
    }

    private func notifyStatus() {
        let status = self.status
        let error = self.lastError
        for observer in statusObservers { observer.handler(status, error) }
    }

    /// Sets a terminal status (`complete`/`fail`) and notifies status observers. The parent delivery
    /// of the done/error event happens on the ordered chain in `makeScope` before this runs.
    private func markTerminal(_ status: SnapshotStatus, error: String?) {
        terminalStatus = status
        lastError = error
        notifyStatus()
    }

    @discardableResult
    public func start(input: SendableValue? = nil) async -> Self {
        // Startup is one processing cycle (see `isProcessing`): entry-action sends to children that
        // bounce back via `enqueueFromChild` queue and drain in order rather than reentering.
        let resolvedInput = input ?? options.input
        isProcessing = true
        _snapshot = await logic.started(input: resolvedInput, host: self)
        await drainLoop()       // drain any startup-enqueued child events, like Actor.start
        isProcessing = false
        emitStartupInspection(actionTypes: logic.startupActionTypes(input: resolvedInput))
        notify(snapshot)
        startDriver(input: resolvedInput)
        return self
    }

    /// Starts the logic's driver: synchronous `setUp` first (so callback receivers/dispose are ready
    /// before `start` returns), then the optional async `run` (streaming logics). No-op for pure
    /// reducers / machines. The scope provides snapshot push, event `receive`, ordered `sendToParent`,
    /// and `emit`.
    private func startDriver(input: SendableValue?) {
        let scope = makeScope(input: input)
        runCleanup = logic.setUp(scope)   // synchronous — done before start() returns
        runTask = Task { [logic, weak self] in
            if let cleanup = await logic.run(scope) {
                await self?.storeRunCleanup(cleanup)
            }
        }
    }

    private func makeScope(input: SendableValue?) -> ActorScope<L.Snapshot> {
        let receivers = self.receivers
        let parentDeliveries = self.parentDeliveries
        let emitListeners = self.emitListeners
        let parent = self.parent
        let id = self.id
        return ActorScope<L.Snapshot>(
            actorId: id,
            input: input,
            update: { [weak self] pushed in await self?.applyExternal(pushed) },
            receive: { handler in receivers.add(handler) },
            sendToParent: { [weak parent] event in parentDeliveries.deliver(to: parent, event) },
            emit: { event in emitListeners.notify(event) },
            complete: { [weak self, weak parent] output in
                parentDeliveries.deliver(to: parent, DoneActorEvent(actorId: id, output: output))
                Task { await self?.markTerminal(.done, error: nil) }
            },
            fail: { [weak self, weak parent] message in
                parentDeliveries.deliver(to: parent, ErrorActorEvent(actorId: id, error: message))
                Task { await self?.markTerminal(.error, error: message) }
            }
        )
    }

    private func storeRunCleanup(_ cleanup: (@Sendable () -> Void)?) {
        runCleanup = cleanup
    }

    /// The startup inspection lifecycle, matching Actor's order: registration[root only] → startup
    /// `.action` events → transition → init event → snapshot. Shared by `start` (which passes the
    /// startup action types) and `start(from:)` (which passes none — restore runs no entry actions).
    private func emitStartupInspection(actionTypes: [String] = []) {
        let settled = snapshot
        system.register(self)
        if parent == nil {
            emitInspection(logic.inspectionRegistrationEvent(
                settled, actor: inspectionActorRef, rootId: inspectionRootId,
                parentSessionId: (parent as? ActorSystemRef)?.sessionId,
                includeDefinition: system.hasInspectors
            ))
        }
        for type in actionTypes {
            emitInspection(.action(rootId: inspectionRootId, actor: inspectionActorRef, actionType: type, triggeringEvent: SystemEvent.`init`))
        }
        emitInspection(logic.inspectionTransitionEvent(settled, event: SystemEvent.`init`, actor: inspectionActorRef, rootId: inspectionRootId))
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: nil, event: SystemEvent.`init`))
        emitInspection(logic.inspectionSnapshotEvent(settled, event: SystemEvent.`init`, actor: inspectionActorRef, rootId: inspectionRootId))
    }

    /// Attributes a child→parent event to its originating child (mirrors `Actor.inspectionSource`).
    private func inspectionSource(for event: any Eventable) -> InspectionActorRef? {
        let actorId: String?
        if let done = event as? DoneActorEvent {
            actorId = done.actorId
        } else if let error = event as? ErrorActorEvent {
            actorId = error.actorId
        } else if let snapshotEvent = event as? SnapshotActorEvent {
            actorId = snapshotEvent.actorId
        } else {
            actorId = nil
        }
        guard let actorId, let child = childRegistry.get(actorId) else { return nil }
        return InspectionActorRef.from(child)
    }

    /// Stops the background driver and all children. Events already in flight still drain.
    public func stop() async {
        runTask?.cancel()
        runTask = nil
        runCleanup?()
        runCleanup = nil
        receivers.removeAll()
        childRegistry.markAllStopped()
        for child in childRegistry.all.values {
            system.unregister(child)
            await child.stop()
        }
        childRegistry.removeAll()
        system.unregister(self)
        // Publish a terminal snapshot so observers/waiters (waitFor, child refs) see termination,
        // matching the old Actor.stop().
        if let current = _snapshot {
            let stopped = logic.stoppedSnapshot(current)
            _snapshot = stopped
            notify(stopped)
        }
    }

    /// Applies a snapshot pushed by `ActorLogic.run`. Dropped once the logic is no longer active,
    /// keeping run-to-completion semantics symmetric with `process`.
    private func applyExternal(_ snapshot: L.Snapshot) {
        guard let current = _snapshot, logic.status(of: current) == .active else { return }
        _snapshot = snapshot
        notify(snapshot)
    }

    public func send(_ event: any Eventable) async {
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: nil, event: event))
        mailbox.append(event)
        await drain()
    }

    /// Listens for `emit(…)` events (the `MachineHost.emit` sink). `"*"` matches all.
    @discardableResult
    public func on(_ eventType: String, handler: @escaping @Sendable (EmittedEvent) -> Void) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (L.Snapshot) -> Void) -> Subscription {
        if let snapshot = _snapshot { handler(snapshot) }
        let id = nextObserverID
        nextObserverID += 1
        observers.append((id: id, handler: handler))
        return Subscription { [weak self] in
            Task { await self?.removeObserver(id: id) }
        }
    }

    private func removeObserver(id: Int) {
        observers.removeAll { $0.id == id }
    }

    private func drainLoop() async {
        while !mailbox.isEmpty {
            await process(mailbox.removeFirst())
        }
    }

    private func drain() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        await drainLoop()
    }

    private func process(_ event: any Eventable) async {
        guard let current = _snapshot, logic.status(of: current) == .active else { return }
        // Runnable logics consume events through their registered receivers; for reducers there are
        // none, so this is a no-op and `handle` does the work.
        for receiver in receivers.current() { receiver(event) }
        let next = await logic.handle(event, current, host: self)
        _snapshot = next
        emitInspection(logic.inspectionTransitionEvent(next, event: event, actor: inspectionActorRef, rootId: inspectionRootId))
        emitInspection(logic.inspectionSnapshotEvent(next, event: event, actor: inspectionActorRef, rootId: inspectionRootId))
        notify(next)
    }

    private func notify(_ snapshot: L.Snapshot) {
        for observer in observers {
            observer.handler(snapshot)
        }
        notifyStatus()
        deliverChildCompletion(snapshot)
    }

    /// For machine children: when the snapshot reaches `.done`/`.error`, deliver the Done/Error event
    /// to the parent on the ordered chain (drives the parent's `invoke` onDone/onError); for
    /// `syncSnapshot`, deliver a `SnapshotActorEvent` per active snapshot. No-op for root actors and
    /// for completing children (task/observable), whose snapshot status stays `.active`.
    private func deliverChildCompletion(_ snapshot: L.Snapshot) {
        guard parent != nil, !childDoneSent else {
            if parent != nil, childSyncSnapshot, logic.status(of: snapshot) == .active {
                parentDeliveries.deliver(to: parent, snapshotEvent(snapshot))
            }
            return
        }
        switch logic.status(of: snapshot) {
        case .done:
            childDoneSent = true
            parentDeliveries.deliver(to: parent, DoneActorEvent(actorId: id, output: logic.output(of: snapshot)))
        case .error:
            childDoneSent = true
            parentDeliveries.deliver(to: parent, ErrorActorEvent(actorId: id, error: lastError ?? "error"))
        case .active where childSyncSnapshot:
            parentDeliveries.deliver(to: parent, snapshotEvent(snapshot))
        default:
            break
        }
    }

    private func snapshotEvent(_ snapshot: L.Snapshot) -> SnapshotActorEvent {
        SnapshotActorEvent(
            actorId: id,
            snapshot: ChildActorSnapshot(id: id, status: .active, value: logic.childSnapshotValue(of: snapshot))
        )
    }

    // MARK: ActorParentRef

    public func enqueueFromChild(_ event: any Eventable) async {
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: inspectionSource(for: event), event: event))
        mailbox.append(event)
        await drain()
    }

    public func inspectSpawnedChild(_ child: any ChildActor, machineId: String?) async {
        emitInspection(.actor(
            rootId: inspectionRootId,
            actor: InspectionActorRef.from(child, machineId: machineId),
            parentSessionId: id,
            definitionJSON: child.definitionJSON
        ))
    }

    // MARK: MachineHost

    public func emit(_ event: EmittedEvent) {
        emitListeners.notify(event)
    }

    public func deliverToChild(id childId: String, event: any Eventable) async {
        guard let child = childRegistry.get(childId) else { return }
        await child.send(event)
    }

    public func enqueueToParent(_ event: any Eventable) async {
        await parent?.enqueueFromChild(event)
    }

    public func sendToParentOrdered(_ event: any Eventable) {
        parentDeliveries.deliver(to: parent, event)
    }

    public func scheduleSelfEvent(timerId: String, delay: Int, event: Event) {
        scheduler.schedule(timerId, delay: delay) { [weak self] in
            Task { await self?.fireSelfEvent(event, timerId: timerId) }
        }
    }

    public func scheduleChildEvent(timerId: String, delay: Int, childId: String, event: Event) {
        scheduler.schedule(timerId, delay: delay) { [weak self] in
            Task { await self?.fireChildEvent(childId: childId, event: event, timerId: timerId) }
        }
    }

    private func fireSelfEvent(_ event: Event, timerId: String) async {
        scheduler.didFire(timerId)
        mailbox.append(event)
        await drain()
    }

    private func fireChildEvent(childId: String, event: Event, timerId: String) async {
        scheduler.didFire(timerId)
        await deliverToChild(id: childId, event: event)
    }

    public func cancelTimer(_ timerId: String) {
        scheduler.cancel(timerId)
    }

    func childActor(id: String) -> (any ChildActor)? {
        childRegistry.get(id)
    }

    public func registerChild(_ child: any ChildActor) {
        system.register(child)
    }

    public func unregisterChild(_ child: any ChildActor) {
        system.unregister(child)
    }

    public func pendingChildSnapshot(_ id: String) -> PersistedChildSnapshot? {
        pendingChildSnapshots[id]
    }
}

// MARK: - Persistence (mirrors Actor.getPersistedSnapshot, gated on a PersistableLogic)

extension Actor where L: PersistableLogic {
    /// A persisted representation of the current snapshot (plus its children). Matches
    /// `Actor.getPersistedSnapshot()`.
    public func getPersistedSnapshot() async throws -> PersistedSnapshot {
        guard let snapshot = _snapshot else {
            throw PersistenceError.actorNotStarted
        }
        let childSnapshots = try await collectPersistedChildSnapshots(from: childRegistry.all)
        return try logic.persistedSnapshot(snapshot, children: childSnapshots)
    }

    /// Starts by **restoring** a persisted snapshot (state + context + children) instead of running
    /// the initial transition. Matches `Actor.start(from:)`. Children persisted under the snapshot
    /// are re-spawned (seeded with their persisted state via `pendingChildSnapshot`).
    @discardableResult
    func restore(from persisted: PersistedSnapshot) async throws -> Self {
        isProcessing = true
        pendingChildSnapshots = persisted.children
        defer { pendingChildSnapshots = [:] }

        _snapshot = try logic.restoredSnapshot(from: persisted)
        // A child restored already-terminal must not re-deliver its Done/Error to the parent (the
        // parent's persisted snapshot already reflects it) — matches MachineChildRef's doneSent guard.
        if parent != nil, logic.status(of: snapshot) != .active {
            childDoneSent = true
        }
        _snapshot = await logic.restoreChildren(snapshot, host: self)
        await drainLoop()
        isProcessing = false

        emitStartupInspection()
        notify(snapshot)
        startDriver(input: options.input)
        return self
    }
}
