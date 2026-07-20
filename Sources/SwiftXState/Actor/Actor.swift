#if hasFeature(Embedded)
// Embedded Swift does not implicitly import the concurrency module the way full Swift does.
import _Concurrency
#endif

#if canImport(Dispatch)
import Dispatch
#endif

/// The generic actor *core*: a mailbox + run-to-completion
/// loop + observers, parameterized purely by an `ActorLogic`. It folds events into snapshots via the
/// logic and notifies subscribers, owning no `Context` itself.
///
/// It also owns the Context-agnostic runtime resources (timer scheduler, child registry, actor
/// system, parent) and conforms to `MachineHosting`, so an *effectful* logic can run side effects /
/// `after` / `invoke` through it. With that, one `Actor<L>` provably hosts every logic shape:
/// hand-written reducers, runnables (callback/task/observable), and full state machines —
/// `Actor<MachineLogic<C>>` reaches parity with `Actor`. See `LogicActorTests`.
public actor Actor<L: ActorLogic>: ParentActorRepresentable, ActorSystemRef, MachineHosting {
    /// The logic this actor runs. `var` (not `let`) only so the machine convenience `start(context:)`
    /// can rebuild it with a context override before the initial transition; otherwise immutable.
    var logic: L
    private var _snapshot: L.Snapshot?
    private var mailbox: [any Eventable] = []
    /// Live `enq.listen` subscriptions to child actors; cancelled when this actor stops.
    private var listenerSubscriptions: [Subscription] = []
    private var isProcessing = false
    private var observers: [(id: Int, handler: @Sendable (L.Snapshot) -> Void)] = []
    private var nextObserverID = 0
    /// Continuation registry for the additive `snapshots(bufferingPolicy:)` AsyncStream API. Fed by the
    /// same `notify` as `observers` (the callback path is unchanged); shares the `nextObserverID` id space.
    private var snapshotContinuations: [Int: AsyncStream<L.Snapshot>.Continuation] = [:]
    private var runTask: Task<Void, Never>?
    // Runnable-logic (callback/task/observable) support: incoming-event receivers (lock-boxed so a
    // background `run` can register without a racing hop), the run's cleanup, and one serial chain
    // for outbound parent deliveries (so `sendToParent` keeps order centrally — the XState-v6 lesson,
    // no per-child ParentDeliveryChain).
    private nonisolated let receivers = ReceiverBox()
    private var runCleanup: (@Sendable () -> Void)?
    private nonisolated let parentDeliveries = ParentDeliveryChain()
    // Terminal status for completing children (task/observable/transition/store) set via the scope's
    // complete/fail; overrides the snapshot-derived status. `statusObservers` lets the ChildActorRepresentable
    // adapter cache status changes.
    private var terminalStatus: SnapshotStatus?
    private var lastError: String?
    // The single source of truth for "this actor was stopped via `stop()`". Unlike `markTerminal`
    // (completing children), `stop()` sets no `terminalStatus`, and for task/observable/transition/
    // reducer logics its `stoppedSnapshot` is identity so the snapshot's own status stays `.active`.
    // Without this flag a `snapshots()` registered *after* stop would enroll a continuation into the
    // already-drained `snapshotContinuations` (which nothing ever finishes — the stream hangs forever).
    private var isStopped = false
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
    // Embedded prohibits `weak`; see BackRef.swift for why a strong parent link is sound there.
    #if hasFeature(Embedded)
    private var parent: (any ParentActorRepresentable)?
    #else
    private weak var parent: (any ParentActorRepresentable)?
    #endif
    private nonisolated let system: ActorSystem
    private nonisolated let options: ActorOptions
    private nonisolated let clock: ClockHandle
    private nonisolated let inspectable: Bool

    public nonisolated let id: String

    #if canImport(Darwin)
    // Custom executor backing: `ActorOptions.useMainExecutor` runs on the MainActor's serial executor
    // (no thread hop from the main actor, for SwiftUI); otherwise a dedicated `ActorSerialExecutor`
    // preserves off-main serialization. `ownedExecutor` retains that executor for the actor's lifetime
    // (an `UnownedSerialExecutor` does not retain). NB: backing the actor *directly* with
    // `DispatchSerialQueue.asUnownedSerialExecutor()` did NOT serialize the actor — TSan caught real
    // races and dropped child-done events; `ActorSerialExecutor`'s explicit `enqueue` fixes it.
    private nonisolated let ownedExecutor: ActorSerialExecutor?
    private nonisolated let _unownedExecutor: UnownedSerialExecutor

    public nonisolated var unownedExecutor: UnownedSerialExecutor { _unownedExecutor }
    #endif

    public nonisolated var actorSystem: ActorSystem { system }
    public nonisolated var sessionId: String { id }
    public nonisolated var systemId: String? { options.systemId }
    public nonisolated var hostClock: ClockHandle { clock }

    public init(
        _ logic: L,
        id: String = randomUUIDString(),
        options: ActorOptions = ActorOptions(),
        parent: (any ParentActorRepresentable)? = nil,
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
            self.ownedExecutor = nil
            self._unownedExecutor = MainActor.sharedUnownedExecutor
        } else {
            let executor = ActorSerialExecutor(id: id)
            self.ownedExecutor = executor
            self._unownedExecutor = executor.asUnownedSerialExecutor()
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
        if isStopped { return .stopped }
        guard let snapshot = _snapshot else { return .stopped }
        return logic.status(of: snapshot)
    }

    /// The last error message (set by `fail`), for `ChildActorRepresentable.errorMessage`.
    var errorMessage: String? { lastError }

    /// Observe status changes (snapshot-derived or terminal). Used by the `ChildActorRepresentable` adapter to
    /// cache status synchronously. Fires immediately with the current status.
    @discardableResult
    func subscribeStatus(_ handler: @escaping @Sendable (SnapshotStatus, String?) -> Void) -> Subscription {
        handler(status, lastError)
        let id = nextObserverID
        nextObserverID += 1
        statusObservers.append((id: id, handler: handler))
        let selfRef = BackRef(self)
        return Subscription {
            Task { await selfRef.value?.removeStatusObserver(id: id) }
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
        let selfRef = BackRef(self)
        runTask = Task { [logic] in
            if let cleanup = await logic.run(scope) {
                await selfRef.value?.storeRunCleanup(cleanup)
            }
        }
    }

    private func makeScope(input: SendableValue?) -> ActorScope<L.Snapshot> {
        let receivers = self.receivers
        let parentDeliveries = self.parentDeliveries
        let emitListeners = self.emitListeners
        let parentRef = ParentRef(self.parent)
        let selfRef = BackRef(self)
        let id = self.id
        return ActorScope<L.Snapshot>(
            actorId: id,
            input: input,
            update: { pushed in await selfRef.value?.applyExternal(pushed) },
            receive: { handler in receivers.add(handler) },
            sendToParent: { event in parentDeliveries.deliver(to: parentRef.value, event) },
            emit: { event in emitListeners.notify(event) },
            complete: { output in
                parentDeliveries.deliver(to: parentRef.value, DoneActorEvent(actorId: id, output: output))
                Task { await selfRef.value?.markTerminal(.done, error: nil) }
            },
            fail: { message in
                parentDeliveries.deliver(to: parentRef.value, ErrorActorEvent(actorId: id, error: message))
                Task { await selfRef.value?.markTerminal(.error, error: message) }
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
        _ = system.register(self)
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
        isStopped = true
        runTask?.cancel()
        runTask = nil
        runCleanup?()
        runCleanup = nil
        receivers.removeAll()
        for sub in listenerSubscriptions { sub.cancel() }
        listenerSubscriptions.removeAll()
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
        for continuation in snapshotContinuations.values { continuation.finish() }
        snapshotContinuations.removeAll()

        // Drop the references that would otherwise form a retain cycle. On platforms with `weak`
        // this is hygiene; on Embedded Swift, where the same links are strong (see `BackRef`), it is
        // what makes stopping an actor actually release it.
        //
        // `parent` is the cycle: the parent holds this actor in its `ChildRegistry` while this actor
        // points back. `scheduler.cancelAll()` releases pending timer closures, each of which
        // captures `self`. Everything else above — run task, run cleanup, receivers, listener
        // subscriptions, children, snapshot continuations — was already being released here.
        scheduler.cancelAll()
        parent = nil
        pendingChildSnapshots.removeAll()
    }

    /// Applies a snapshot pushed by `ActorLogic.run`. Dropped once the logic is no longer active,
    /// keeping run-to-completion semantics symmetric with `process`.
    private func applyExternal(_ snapshot: L.Snapshot) {
        guard let current = _snapshot, logic.status(of: current) == .active else { return }
        _snapshot = snapshot
        notify(snapshot)
    }

    public func send(_ event: any Eventable) async {
        // `internalEvents` may be raised from within the machine but are rejected from the outside.
        if logic.internalEventTypes.contains(event.type) { return }
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: nil, event: event))
        mailbox.append(event)
        await drain()
    }

    /// `enq.listen`: subscribe to a child's emitted events and relay a mapped event back into this
    /// actor. The `Subscription` is retained here and cancelled on `stop()`.
    public func listen(childId: String, eventType: String,
                       map: @escaping @Sendable (EmittedEvent) -> (any Eventable)?) async {
        guard let child = childRegistry.get(childId) else { return }
        let selfRef = BackRef(self)
        let sub = await child.on(eventType) { emitted in
            guard let mapped = map(emitted) else { return }
            Task { await selfRef.value?.receiveRelay(mapped) }
        }
        listenerSubscriptions.append(sub)
    }

    /// `enq.subscribeTo`: subscribe to a child's snapshot changes and relay a mapped event back.
    public func subscribeToChild(childId: String,
                                 map: @escaping @Sendable (ChildActorSnapshot) -> (any Eventable)?) async {
        guard let child = childRegistry.get(childId) else { return }
        let selfRef = BackRef(self)
        let sub = await child.subscribe { snapshot in
            guard let mapped = map(snapshot) else { return }
            Task { await selfRef.value?.receiveRelay(mapped) }
        }
        listenerSubscriptions.append(sub)
    }

    /// `enq.subscribeTo(atom)`: subscribe to a reactive atom and relay each mapped event back into this
    /// actor. The `Subscription` is retained here and cancelled on `stop()`.
    public func subscribeToAtom(
        _ subscribe: @escaping @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Subscription
    ) async {
        let selfRef = BackRef(self)
        let sub = subscribe { event in
            Task { await selfRef.value?.receiveRelay(event) }
        }
        listenerSubscriptions.append(sub)
    }

    /// Deliver a relayed event from a listened child. It is the machine reacting to its own child, so
    /// it bypasses the external `internalEvents` gate (an internal reaction, not an outside send).
    private func receiveRelay(_ event: any Eventable) async {
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: nil, event: event))
        mailbox.append(event)
        await drain()
    }

    /// Listens for `emit(…)` events (the `MachineHosting.emit` sink). `"*"` matches all.
    @discardableResult
    public func on(_ eventType: String, handler: @escaping @Sendable (EmittedEvent) -> Void) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }

    /// Snapshot subscription erased to a `ChildActorSnapshot` (for a parent's `enq.subscribeTo`). Runs
    /// inside the actor so `logic` is accessible for the value/status mapping.
    func subscribeChildSnapshot(id: String, _ handler: @escaping @Sendable (ChildActorSnapshot) -> Void) -> Subscription {
        let capturedLogic = logic
        return subscribe { snap in
            handler(ChildActorSnapshot(id: id,
                                       status: capturedLogic.status(of: snap),
                                       value: capturedLogic.childSnapshotValue(of: snap)))
        }
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (L.Snapshot) -> Void) -> Subscription {
        if let snapshot = _snapshot { handler(snapshot) }
        let id = nextObserverID
        nextObserverID += 1
        observers.append((id: id, handler: handler))
        let selfRef = BackRef(self)
        return Subscription {
            Task { await selfRef.value?.removeObserver(id: id) }
        }
    }

    private func removeObserver(id: Int) {
        observers.removeAll { $0.id == id }
    }

    /// An `AsyncStream` of snapshots — the async-sequence sibling of `subscribe(_:)`, added *alongside*
    /// it: both are fed by the same `notify`, and the callback path is unchanged. `AsyncStream` is
    /// unicast, so each call mints an independent stream + continuation, registered on the actor. The
    /// current snapshot (if the actor has started) is replayed as the first element — BehaviorSubject
    /// semantics, matching `subscribe`. Default `.bufferingNewest(1)`: a slow consumer coalesces to the
    /// latest snapshot (correct for `@Observable` / SwiftUI, and bounds memory to one element per
    /// subscriber); pass `.unbounded` when you must observe every intermediate snapshot (e.g. a
    /// state-sequence waiter). Cancellation is by ending the `for await` loop (or cancelling its task),
    /// which fires the stream's `onTermination` and deregisters the continuation.
    ///
    /// Note the one behavioural nuance vs `subscribe`: because registration hops onto the actor,
    /// the replayed "current" value is the snapshot at *registration time*, not at the call site.
    public nonisolated func snapshots(
        bufferingPolicy: AsyncStream<L.Snapshot>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<L.Snapshot> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            Task { await self.registerSnapshotStream(continuation) }
        }
    }

    private func registerSnapshotStream(_ continuation: AsyncStream<L.Snapshot>.Continuation) {
        if let snapshot = _snapshot { continuation.yield(snapshot) }   // current-value replay (matches subscribe)
        guard terminalStatus == nil, !isStopped else {                 // already terminal/stopped: replay-then-finish
            continuation.finish()
            return
        }
        let id = nextObserverID
        nextObserverID += 1
        snapshotContinuations[id] = continuation
        let selfRef = BackRef(self)
        continuation.onTermination = { _ in
            Task { await selfRef.value?.removeSnapshotContinuation(id) }
        }
    }

    private func removeSnapshotContinuation(_ id: Int) {
        snapshotContinuations[id] = nil
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
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)          // additive fan-out; callbacks above are the backbone
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

    // MARK: ParentActorRepresentable

    public func enqueueFromChild(_ event: any Eventable) async {
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: inspectionSource(for: event), event: event))
        mailbox.append(event)
        await drain()
    }

    public func inspectSpawnedChild(_ child: any ChildActorRepresentable, machineId: String?) async {
        emitInspection(.actor(
            rootId: inspectionRootId,
            actor: InspectionActorRef.from(child, machineId: machineId),
            parentSessionId: id,
            definitionJSON: child.definitionJSON
        ))
    }

    // MARK: MachineHosting

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
        let selfRef = BackRef(self)
        scheduler.schedule(timerId, delay: delay) {
            Task { await selfRef.value?.fireSelfEvent(event, timerId: timerId) }
        }
    }

    public func scheduleChildEvent(timerId: String, delay: Int, childId: String, event: Event) {
        let selfRef = BackRef(self)
        scheduler.schedule(timerId, delay: delay) {
            Task { await selfRef.value?.fireChildEvent(childId: childId, event: event, timerId: timerId) }
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

    func childActor(id: String) -> (any ChildActorRepresentable)? {
        childRegistry.get(id)
    }

    public func registerChild(_ child: any ChildActorRepresentable) {
        _ = system.register(child)
    }

    public func unregisterChild(_ child: any ChildActorRepresentable) {
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
