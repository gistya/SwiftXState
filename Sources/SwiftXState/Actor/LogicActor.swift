import Foundation

/// The Context-agnostic runtime resources an effectful `ActorLogic` needs from its host actor while
/// handling an event — timers, children, parent/system wiring, emit. Because `LogicActor` provides
/// this and `ActorLogic.handle` takes the host as an **`isolated`** parameter, an effectful logic
/// (`MachineLogic`) runs its side-effect dispatch / `after` / `invoke` *inside the actor's isolation*
/// with no hops, exactly as `StateActor` does inline — but without the actor needing to know the
/// logic's `Context`. All the Context-specific work (the action switch, `makeChildActorRef`) lives in
/// the logic; the host only exposes these non-generic primitives.
protocol MachineHost: _Concurrency.Actor, ActorParentRef, ActorSystemRef {
    var childRegistry: ChildRegistry { get }
    var hostClock: any Clock { get }
    func emit(_ event: EmittedEvent)
    func deliverToChild(id childId: String, event: any Eventable) async
    func enqueueToParent(_ event: any Eventable) async
    func scheduleSelfEvent(timerId: String, delay: Int, event: Event)
    func scheduleChildEvent(timerId: String, delay: Int, childId: String, event: Event)
    func cancelTimer(_ timerId: String)
    func registerChild(_ child: any ChildActorRef)
    func unregisterChild(_ child: any ChildActorRef)

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
/// `after` / `invoke` through it. With that, one `LogicActor<L>` provably hosts every logic shape:
/// hand-written reducers, runnables (callback/task/observable), and full state machines —
/// `LogicActor<MachineLogic<C>>` reaches parity with `Actor`. See `LogicActorTests`.
actor LogicActor<L: ActorLogic>: ActorParentRef, ActorSystemRef, MachineHost {
    private let logic: L
    private var _snapshot: L.Snapshot?
    private var mailbox: [any Eventable] = []
    private var isProcessing = false
    private var observers: [(id: Int, handler: @Sendable (L.Snapshot) -> Void)] = []
    private var nextObserverID = 0
    private var runTask: Task<Void, Never>?

    private let emitListeners = EmitListeners()
    let childRegistry = ChildRegistry()
    private let scheduler: DelayScheduler
    private weak var parent: (any ActorParentRef)?
    private nonisolated let system: ActorSystem
    private nonisolated let options: ActorOptions
    private nonisolated let clock: any Clock
    private nonisolated let inspectable: Bool

    nonisolated let id: String

    nonisolated var actorSystem: ActorSystem { system }
    nonisolated var sessionId: String { id }
    nonisolated var systemId: String? { options.systemId }
    nonisolated var hostClock: any Clock { clock }

    init(
        _ logic: L,
        id: String = UUID().uuidString,
        options: ActorOptions = ActorOptions(),
        parent: (any ActorParentRef)? = nil,
        system: ActorSystem? = nil
    ) {
        self.logic = logic
        self.id = id
        self.options = options
        self.clock = options.clock
        self.inspectable = options.inspectable
        self.scheduler = DelayScheduler(clock: options.clock)
        self.parent = parent
        self.system = system ?? parent?.actorSystem ?? ActorSystem()
        if parent == nil {
            self.system.setRootIdIfNeeded(id)
        }
        if inspectable, let inspect = options.inspect {
            self.system.inspect(inspect)
        }
    }

    var inspectionActorRef: InspectionActorRef {
        InspectionActorRef.from(self, machineId: logic.inspectionMachineId())
    }

    var inspectionRootId: String {
        system.rootSessionId ?? id
    }

    /// Whether intermediate microstep snapshots are recorded (and thus inspectable). We only need
    /// them when an inspector may be attached, so gate on `inspectable`.
    var recordsMicrosteps: Bool { inspectable }

    /// `event` is an `@autoclosure` so the (potentially expensive) `InspectionEvent` — which
    /// `Mirror`-encodes the whole `Context` — is only built when an inspector is actually attached,
    /// exactly as in `Actor`. A nil result (a non-inspected logic) emits nothing.
    func emitInspection(_ event: @autoclosure () -> InspectionEvent?) {
        guard inspectable, system.hasInspectors else { return }
        if let event = event() { system.sendInspection(event) }
    }

    /// The current snapshot. Traps if the actor hasn't been started.
    var snapshot: L.Snapshot {
        guard let snapshot = _snapshot else {
            fatalError("LogicActor has not been started. Call start() first.")
        }
        return snapshot
    }

    var status: SnapshotStatus {
        guard let snapshot = _snapshot else { return .stopped }
        return logic.status(of: snapshot)
    }

    @discardableResult
    func start(input: SendableValue? = nil) async -> Self {
        // Startup is one processing cycle (see `isProcessing`): entry-action sends to children that
        // bounce back via `enqueueFromChild` queue and drain in order rather than reentering.
        isProcessing = true
        let snapshot = await logic.started(input: input ?? options.input, host: self)
        _snapshot = snapshot
        isProcessing = false
        system.register(self)
        // Inspection lifecycle for startup, matching Actor's order: registration (root only),
        // transition, incoming init event, snapshot.
        if parent == nil {
            emitInspection(logic.inspectionRegistrationEvent(
                snapshot, actor: inspectionActorRef, rootId: inspectionRootId,
                parentSessionId: (parent as? ActorSystemRef)?.sessionId,
                includeDefinition: system.hasInspectors
            ))
        }
        emitInspection(logic.inspectionTransitionEvent(snapshot, event: SystemEvent.`init`, actor: inspectionActorRef, rootId: inspectionRootId))
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: nil, event: SystemEvent.`init`))
        emitInspection(logic.inspectionSnapshotEvent(snapshot, event: SystemEvent.`init`, actor: inspectionActorRef, rootId: inspectionRootId))
        notify(snapshot)
        // Launch the optional background driver (no-op for pure reducers / machines). The scope hops
        // each pushed snapshot back onto this actor's isolation via `applyExternal`.
        let scope = ActorScope<L.Snapshot> { [weak self] pushed in
            await self?.applyExternal(pushed)
        }
        runTask = Task { [logic] in await logic.run(scope) }
        return self
    }

    /// Stops the background driver and all children. Events already in flight still drain.
    func stop() async {
        runTask?.cancel()
        runTask = nil
        childRegistry.markAllStopped()
        for child in childRegistry.all.values {
            system.unregister(child)
            await child.stop()
        }
        childRegistry.removeAll()
        system.unregister(self)
    }

    /// Applies a snapshot pushed by `ActorLogic.run`. Dropped once the logic is no longer active,
    /// keeping run-to-completion semantics symmetric with `process`.
    private func applyExternal(_ snapshot: L.Snapshot) {
        guard let current = _snapshot, logic.status(of: current) == .active else { return }
        _snapshot = snapshot
        notify(snapshot)
    }

    func send(_ event: any Eventable) async {
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: nil, event: event))
        mailbox.append(event)
        await drain()
    }

    /// Listens for `emit(…)` events (the `MachineHost.emit` sink). `"*"` matches all.
    @discardableResult
    func on(_ eventType: String, handler: @escaping @Sendable (EmittedEvent) -> Void) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }

    @discardableResult
    func subscribe(_ handler: @escaping @Sendable (L.Snapshot) -> Void) -> Subscription {
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

    private func drain() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while !mailbox.isEmpty {
            await process(mailbox.removeFirst())
        }
    }

    private func process(_ event: any Eventable) async {
        guard let current = _snapshot, logic.status(of: current) == .active else { return }
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
    }

    // MARK: ActorParentRef

    func enqueueFromChild(_ event: any Eventable) async {
        // Source attribution (mapping the event back to the originating child) is not yet ported;
        // the source is nil for now. The event/transition/snapshot stream is otherwise faithful.
        emitInspection(.event(rootId: inspectionRootId, actor: inspectionActorRef, source: nil, event: event))
        mailbox.append(event)
        await drain()
    }

    func inspectSpawnedChild(_ child: any ChildActorRef, machineId: String?) async {
        emitInspection(.actor(
            rootId: inspectionRootId,
            actor: InspectionActorRef.from(child, machineId: machineId),
            parentSessionId: id,
            definitionJSON: child.definitionJSON
        ))
    }

    // MARK: MachineHost

    func emit(_ event: EmittedEvent) {
        emitListeners.notify(event)
    }

    func deliverToChild(id childId: String, event: any Eventable) async {
        guard let child = childRegistry.get(childId) else { return }
        await child.send(event)
    }

    func enqueueToParent(_ event: any Eventable) async {
        await parent?.enqueueFromChild(event)
    }

    func scheduleSelfEvent(timerId: String, delay: Int, event: Event) {
        scheduler.schedule(timerId, delay: delay) { [weak self] in
            Task { await self?.fireSelfEvent(event, timerId: timerId) }
        }
    }

    func scheduleChildEvent(timerId: String, delay: Int, childId: String, event: Event) {
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

    func cancelTimer(_ timerId: String) {
        scheduler.cancel(timerId)
    }

    func registerChild(_ child: any ChildActorRef) {
        system.register(child)
    }

    func unregisterChild(_ child: any ChildActorRef) {
        system.unregister(child)
    }
}
