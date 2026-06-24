import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// A running instance of a `StateMachine` — the live process you `send` events to and read
/// `snapshot` from. Create one with `createActor(_:)`, then `start()` it. Thread-safe.
///
/// ```swift
/// let actor = createActor(toggle).start()
/// actor.send(Event("TOGGLE"))
/// actor.snapshot.matches("on")   // true
/// ```
public actor Actor<Context: Sendable>: ActorParentRef, ActorSystemRef {
    private var _snapshot: MachineSnapshot<Context>?
    private var observers: [(id: Int, handler: (MachineSnapshot<Context>) -> Void)] = []
    private var nextObserverID = 0
    private let emitListeners = EmitListeners()
    private let childRegistry = ChildRegistry()
    private var pendingChildSnapshots: [String: PersistedChildSnapshot] = [:]
    private var mailbox: [any Eventable] = []
    /// True while a drain loop is processing the mailbox. Guards against actor reentrancy: an event
    /// enqueued while we're mid-`processEvent` (e.g. a child's `sendParent` triggered by a `sendTo`
    /// to that child, delivered during an `await`) is left for the active drain loop rather than
    /// processed reentrantly — which would otherwise mutate `_snapshot` only to be clobbered when the
    /// outer `processEvent` writes its now-stale result back.
    private var isProcessing = false
    private weak var parent: (any ActorParentRef)?
    private let clock: any Clock
    private let scheduler: DelayScheduler
    private nonisolated let system: ActorSystem
    private nonisolated let options: ActorOptions
    private nonisolated let inspectable: Bool
    /// Whether intermediate microstep snapshots are retained per run-to-completion step. Forced on
    /// when `inspectable` (inspection needs them); otherwise honors `ActorOptions.snapshotMicrosteps`.
    private nonisolated let recordsMicrosteps: Bool
    /// The machine this actor runs.
    public nonisolated let machine: StateMachine<Context>
    /// This actor's session id (unique within its system).
    public nonisolated let id: String

    #if canImport(Darwin)
    // Custom executor backing. When `ActorOptions.useMainExecutor` is set we run on the MainActor's
    // serial executor (no thread hop from the main actor); otherwise we own a dedicated serial
    // dispatch queue, which preserves the usual off-main serialization. `ownedExecutorQueue` retains
    // the queue for the lifetime of the actor (an `UnownedSerialExecutor` does not retain).
    private nonisolated let ownedExecutorQueue: DispatchSerialQueue?
    private nonisolated let _unownedExecutor: UnownedSerialExecutor

    public nonisolated var unownedExecutor: UnownedSerialExecutor { _unownedExecutor }
    #endif

    /// The actor system this actor belongs to.
    public nonisolated var actorSystem: ActorSystem { system }
    /// Alias for `id` — the session id used in inspection and cross-actor references.
    public nonisolated var sessionId: String { id }
    /// The optional stable system id set via `ActorOptions.systemId`.
    public nonisolated var systemId: String? { options.systemId }
    nonisolated var isInspectable: Bool { inspectable }

    /// Lifecycle status: `.active`, `.done` (reached a final state), `.error`, or `.stopped`.
    public var status: SnapshotStatus {
        _snapshot?.status ?? .stopped
    }

    public init(
        _ machine: StateMachine<Context>,
        id: String? = nil,
        options: ActorOptions = ActorOptions(),
        parent: (any ActorParentRef)? = nil,
        system: ActorSystem? = nil
    ) {
        self.machine = machine
        self.id = id ?? machine.id
        self.options = options
        self.inspectable = options.inspectable
        self.recordsMicrosteps = options.inspectable || options.snapshotMicrosteps
        self.clock = options.clock
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
            self.system.setRootIdIfNeeded(self.id)
        }
        if inspectable, let inspect = options.inspect {
            self.system.inspect(inspect)
        }
    }
    
    public nonisolated func typed<Brand: StateID>(as _: Brand.Type = Brand.self) -> TypedActor<Context, Brand> {
        TypedActor(self)
    }

    /// `event` is an `@autoclosure` so the (potentially expensive) `InspectionEvent` — which
    /// `Mirror`-encodes the whole `Context` via `InspectionSnapshot.from` — is only built when an
    /// inspector is actually listening. Without this, a per-microstep `inspect*` call reflects the
    /// entire context graph even with `inspectable: false`, which is O(context) per microstep.
    private func emitInspection(_ event: @autoclosure () -> InspectionEvent) {
        guard inspectable, system.hasInspectors else { return }
        system.sendInspection(event())
    }
    
    public func getSnapshot() -> MachineSnapshot<Context> { snapshot }

    private var inspectionActorRef: InspectionActorRef {
        InspectionActorRef.from(self, machineId: machine.id)
    }

    private var inspectionRootId: String {
        system.rootSessionId ?? id
    }

    private func snapshotForInspection(_ snapshot: MachineSnapshot<Context>) -> MachineSnapshot<Context> {
        let inspectableChildren = snapshot.children.filter { childId, _ in
            guard let child = childRegistry.get(childId) else { return false }
            return child.inspectable
        }
        guard inspectableChildren.count != snapshot.children.count else { return snapshot }
        return MachineSnapshot(
            machine: snapshot.machine,
            value: snapshot.value,
            context: snapshot.context,
            nodes: snapshot._nodes,
            tags: snapshot.tags,
            status: snapshot.status,
            historyValue: snapshot.historyValue,
            output: snapshot.output,
            error: snapshot.error,
            children: inspectableChildren
        )
    }

    private func inspectActorRegistration(snapshot: MachineSnapshot<Context>) {
        emitInspection(.actor(
            rootId: inspectionRootId,
            actor: inspectionActorRef,
            parentSessionId: (parent as? ActorSystemRef)?.sessionId,
            registrationSnapshot: .from(snapshotForInspection(snapshot), actor: inspectionActorRef),
            // Carry the machine's structure so inspectors can graph this actor without a typed
            // reference. Child spawns already include this (see inspectSpawnedChild). Only pay the
            // serialization cost when an inspector is actually listening.
            definitionJSON: (inspectable && system.hasInspectors) ? (try? machine.definitionJSON()) : nil
        ))
    }

    private func inspectIncomingEvent(_ event: any Eventable, source: InspectionActorRef?) {
        emitInspection(.event(
            rootId: inspectionRootId,
            actor: inspectionActorRef,
            source: source,
            event: event
        ))
    }

    private func inspectTransition(_ event: any Eventable, snapshot: MachineSnapshot<Context>) {
        emitInspection(.transition(
            rootId: inspectionRootId,
            actor: inspectionActorRef,
            triggeringEvent: event,
            machineSnapshot: snapshotForInspection(snapshot)
        ))
    }

    private func inspectMicrostep(
        _ event: InspectionEventDescription,
        snapshot: MachineSnapshot<Context>,
        transitions: [ResolvedTransition<Context>]
    ) {
        emitInspection(.microstep(
            rootId: inspectionRootId,
            actor: inspectionActorRef,
            triggeringEvent: event,
            machineSnapshot: snapshotForInspection(snapshot),
            transitions: transitions
        ))
    }

    private func inspectSnapshot(_ event: any Eventable, snapshot: MachineSnapshot<Context>) {
        emitInspection(.snapshot(
            rootId: inspectionRootId,
            actor: inspectionActorRef,
            triggeringEvent: event,
            machineSnapshot: snapshotForInspection(snapshot)
        ))
    }

    private func shouldInspectAction(_ action: ExecutableAction<Context>) -> Bool {
        if case let .spawn(spawn) = action.ref {
            return spawn.inspectable
        }
        return true
    }

    private func inspectAction(_ action: ExecutableAction<Context>, event: any Eventable) {
        guard shouldInspectAction(action) else { return }
        emitInspection(.action(
            rootId: inspectionRootId,
            actor: inspectionActorRef,
            actionType: action.type,
            triggeringEvent: event
        ))
    }

    private func inspectionSource(for event: any Eventable) -> InspectionActorRef? {
        let actorId: String?
        if let done = event as? DoneActorEvent {
            actorId = done.actorId
        } else if let error = event as? ErrorActorEvent {
            actorId = error.actorId
        } else if let snapshot = event as? SnapshotActorEvent {
            actorId = snapshot.actorId
        } else {
            actorId = nil
        }
        guard let actorId, let child = childRegistry.get(actorId) else { return nil }
        return InspectionActorRef.from(child)
    }

    /// The current snapshot of the actor.
    public var snapshot: MachineSnapshot<Context> {
        guard let snapshot = _snapshot else {
            fatalError("Actor has not been started. Call start() first.")
        }
        return snapshot
    }

    /// Returns a persisted representation of the current actor state.
    public func getPersistedSnapshot() async throws -> PersistedSnapshot where Context: Codable {
        guard let snapshot = _snapshot else {
            throw PersistenceError.actorNotStarted
        }
        let childSnapshots = try await collectPersistedChildSnapshots(from: childRegistry.all)
        return try SwiftXState.getPersistedSnapshot(from: snapshot, children: childSnapshots)
    }

    /// Starts the actor by **restoring** a previously persisted snapshot (state + context +
    /// children), rather than running the initial transition. Use for replay / resume.
    @discardableResult
    public func start(
        from persisted: PersistedSnapshot,
        context: Context? = nil
    ) async -> Self where Context: Codable {
        // Treat startup as one processing cycle: child events raised during entry/restore queue and
        // drain in order rather than reentering (see `isProcessing`).
        isProcessing = true
        defer { isProcessing = false }
        pendingChildSnapshots = persisted.children
        defer { pendingChildSnapshots = [:] }

        do {
            _snapshot = try restoreSnapshot(
                machine: machine,
                persisted: persisted,
                context: context
            )
        } catch {
            fatalError("Failed to restore persisted snapshot: \(error)")
        }

        guard let snapshot = _snapshot else { return self }

        updateDelayedTransitions(
            entered: StateNodeSet(snapshot._nodes),
            exited: StateNodeSet(),
            snapshot: snapshot,
            event: SystemEvent.`init`
        )
        await updateChildActors(
            entered: StateNodeSet(snapshot._nodes),
            exited: StateNodeSet(),
            snapshot: snapshot,
            event: SystemEvent.`init`
        )
        await restoreSpawnChildren(snapshot: snapshot, event: SystemEvent.`init`)
        await drainLoop()
        system.register(self)
        if parent == nil {
            system.setRootIdIfNeeded(id)
            inspectActorRegistration(snapshot: snapshot)
        }
        inspectIncomingEvent(SystemEvent.`init`, source: nil)
        inspectTransition(SystemEvent.`init`, snapshot: snapshot)
        notify(snapshot, event: SystemEvent.`init`)
        return self
    }

    /// Starts the actor and runs the initial transition (entering the initial state, running
    /// entry actions, and spawning invoked children). Returns `self` so you can chain
    /// `createActor(m).start()`. `input` feeds the machine's `contextFromInput`.
    @discardableResult
    public func start(input: SendableValue? = nil, context: Context? = nil) async -> Self {
        // Treat startup as one processing cycle (see `isProcessing`): entry-action sends to children
        // that bounce back via `sendParent` queue and drain in order instead of reentering and
        // clobbering the snapshot written below.
        isProcessing = true
        defer { isProcessing = false }
        let resolvedInput = input ?? options.input
        let (snapshot, actions) = initialTransition(machine, input: resolvedInput, context: context)
        _snapshot = snapshot
        _snapshot = await runSideEffectActions(snapshot: snapshot, actions: actions, event: SystemEvent.`init`)
        updateDelayedTransitions(
            entered: StateNodeSet(_snapshot!._nodes),
            exited: StateNodeSet(),
            snapshot: _snapshot!,
            event: SystemEvent.`init`
        )
        await updateChildActors(
            entered: StateNodeSet(_snapshot!._nodes),
            exited: StateNodeSet(),
            snapshot: _snapshot!,
            event: SystemEvent.`init`
        )
        await drainLoop()
        system.register(self)
        if parent == nil {
            system.setRootIdIfNeeded(id)
            inspectActorRegistration(snapshot: _snapshot!)
        }
        for action in actions where shouldInspectAction(action) {
            inspectAction(action, event: SystemEvent.`init`)
        }
        inspectTransition(SystemEvent.`init`, snapshot: _snapshot!)
        inspectIncomingEvent(SystemEvent.`init`, source: nil)
        notify(_snapshot!, event: SystemEvent.`init`)
        return self
    }

    /// Stops the actor and all invoked children.
    public func stop() async {
        await stopAllChildren()
        system.unregister(self)
        if var snapshot = _snapshot {
            snapshot = MachineSnapshot(
                machine: snapshot.machine,
                value: snapshot.value,
                context: snapshot.context,
                nodes: snapshot._nodes,
                tags: snapshot.tags,
                status: .stopped,
                historyValue: snapshot.historyValue,
                output: snapshot.output,
                error: snapshot.error,
                children: [:]
            )
            _snapshot = snapshot
            notify(snapshot, event: SystemEvent.stop)
        }
    }

    /// Sends an event to the actor.
    public func send(_ event: any Eventable) async {
        inspectIncomingEvent(event, source: nil)
        mailbox.append(event)
        await drain()
    }

    public func enqueueFromChild(_ event: any Eventable) async {
        inspectIncomingEvent(event, source: inspectionSource(for: event))
        mailbox.append(event)
        await drain()
    }

    /// Processes the mailbox to completion, one event at a time. A reentrant call (an event enqueued
    /// while a drain is already running) just leaves its event on the mailbox and returns — the active
    /// loop picks it up after the current event finishes. This is what keeps run-to-completion
    /// semantics and prevents the snapshot-clobber described on `isProcessing`.
    private func drain() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        await drainLoop()
    }

    private func drainLoop() async {
        while !mailbox.isEmpty {
            let event = mailbox.removeFirst()
            await processEvent(event)
        }
    }

    private func processEvent(_ event: any Eventable) async {
        guard let current = _snapshot else {
            fatalError("Actor has not been started. Call start() first.")
        }
        guard current.status == .active else { return }

        let previousNodes = current._nodes
        let (nextSnapshot, actions, microsteps) = macrostep(
            snapshot: current,
            event: event,
            isInitial: false,
            recordMicrosteps: recordsMicrosteps
        )
        _snapshot = await runSideEffectActions(snapshot: nextSnapshot, actions: actions, event: event)

        for step in microsteps {
            inspectMicrostep(step.event, snapshot: step.snapshot, transitions: step.transitions)
        }
        for action in actions {
            inspectAction(action, event: event)
        }
        inspectTransition(event, snapshot: _snapshot!)

        let previousSet = StateNodeSet(previousNodes)
        let newSet = StateNodeSet(_snapshot!._nodes)
        var entered = StateNodeSet<Context>()
        var exited = StateNodeSet<Context>()

        for node in newSet where !previousSet.contains(node) {
            entered.insert(node)
        }
        for node in previousSet where !newSet.contains(node) {
            exited.insert(node)
        }

        updateDelayedTransitions(
            entered: entered,
            exited: exited,
            snapshot: _snapshot!,
            event: event
        )
        await updateChildActors(
            entered: entered,
            exited: exited,
            snapshot: _snapshot!,
            event: event
        )
        notify(_snapshot!, event: event)
    }

    private func updateDelayedTransitions(
        entered: StateNodeSet<Context>,
        exited: StateNodeSet<Context>,
        snapshot: MachineSnapshot<Context>,
        event: any Eventable
    ) {
        for node in exited {
            for schedule in node.afterSchedules {
                cancelDelayedTransition(schedule.eventType)
            }
        }

        let args = ActionArgs(context: snapshot.context, event: event)
        for node in entered {
            for schedule in node.afterSchedules {
                let delay = resolveAfterDelay(
                    delayKey: schedule.delayKey,
                    args: args,
                    delays: machine.implementations.delays
                )
                scheduleDelayedTransition(
                    eventType: schedule.eventType,
                    delay: delay,
                    timerId: schedule.eventType
                )
            }
        }
    }

    private func updateChildActors(
        entered: StateNodeSet<Context>,
        exited: StateNodeSet<Context>,
        snapshot: MachineSnapshot<Context>,
        event: any Eventable
    ) async {
        for node in exited {
            for invoke in node.invokeConfigs {
                await stopChild(id: invoke.id)
            }
        }

        let args = ActionArgs(context: snapshot.context, event: event)
        for node in entered {
            for invoke in node.invokeConfigs {
                let input = invoke.input?(args)
                if let child = makeChildActorRef(
                    from: invoke.src,
                    id: invoke.id,
                    systemId: invoke.systemId,
                    input: input,
                    syncSnapshot: invoke.syncSnapshot,
                    inspectable: invoke.inspectable,
                    parent: self,
                    implementations: machine.implementations,
                    options: ActorOptions(clock: clock),
                    persistedChild: pendingChildSnapshots[invoke.id],
                    opaqueRestorePolicy: invoke.opaqueRestorePolicy
                ) {
                    childRegistry.add(invoke.id, child)
                    system.register(child)
                    if child.inspectable {
                        inspectSpawnedChild(child, machineId: child.machineId)
                    }
                    await child.start()
                }
            }
        }

        syncChildrenSnapshot()
    }

    func spawnFromAction(_ spawn: SpawnRef<Context>, args: ActionArgs<Context>) async {
        let childId = spawn.id ?? UUID().uuidString
        guard !childRegistry.contains(childId) else { return }
        let input = spawn.input?(args)
        if let child = makeChildActorRef(
            from: spawn.src,
            id: childId,
            systemId: spawn.systemId,
            input: input,
            syncSnapshot: spawn.syncSnapshot,
            inspectable: spawn.inspectable,
            parent: self,
            implementations: machine.implementations,
            options: ActorOptions(clock: clock),
            persistedChild: pendingChildSnapshots[childId],
            opaqueRestorePolicy: spawn.opaqueRestorePolicy
        ) {
            childRegistry.add(childId, child)
            system.register(child)
            if child.inspectable {
                inspectSpawnedChild(child, machineId: child.machineId)
            }
            await child.start()
        }
        syncChildrenSnapshot()
    }

    /// Re-spawns machine children created via `spawnChild` entry actions when hydrating.
    private func restoreSpawnChildren(
        snapshot: MachineSnapshot<Context>,
        event: any Eventable
    ) async {
        let args = ActionArgs(context: snapshot.context, event: event)
        for node in snapshot._nodes {
            for action in node.entry {
                guard case let .spawn(spawn) = action else { continue }
                await spawnFromAction(spawn, args: args)
            }
        }
    }

    func stopChild(id: String) async {
        guard let child = childRegistry.remove(id) else { return }
        childRegistry.markStopped(id)
        system.unregister(child)
        await child.stop()
        syncChildrenSnapshot()
    }

    private func stopAllChildren() async {
        childRegistry.markAllStopped()
        for child in childRegistry.all.values {
            system.unregister(child)
            await child.stop()
        }
        childRegistry.removeAll()
    }

    private func syncChildrenSnapshot() {
        guard var snapshot = _snapshot else { return }
        childRegistry.reconcileStopped()
        var childSnapshots = childRegistry.snapshots()
        for (id, existing) in snapshot.children where childSnapshots[id] == nil && !childRegistry.wasStopped(id) {
            childSnapshots[id] = existing
        }
        snapshot = MachineSnapshot(
            machine: snapshot.machine,
            value: snapshot.value,
            context: snapshot.context,
            nodes: snapshot._nodes,
            tags: snapshot.tags,
            status: snapshot.status,
            historyValue: snapshot.historyValue,
            output: snapshot.output,
            error: snapshot.error,
            children: childSnapshots
        )
        _snapshot = snapshot
    }

    func scheduleDelayedTransition(eventType: String, delay: Int, timerId: String) {
        scheduler.schedule(timerId, delay: delay) { [weak self] in
            Task { await self?.sendDelayed(Event(eventType), timerId: timerId) }
        }
    }

    func scheduleDelayedSendTo(
        childId: String,
        event: Event,
        delay: Int,
        timerId: String
    ) {
        scheduler.schedule(timerId, delay: delay) { [weak self] in
            Task { await self?.sendDelayedToChild(childId: childId, event: event, timerId: timerId) }
        }
    }

    private func sendDelayed(_ event: Event, timerId: String) async {
        scheduler.didFire(timerId)
        inspectIncomingEvent(event, source: nil)
        mailbox.append(event)
        await drain()
    }

    private func sendDelayedToChild(childId: String, event: Event, timerId: String) async {
        scheduler.didFire(timerId)
        await deliverToChild(id: childId, event: event)
    }

    func deliverToChild(id childId: String, event: any Eventable) async {
        guard let child = childRegistry.get(childId) else { return }
        if child.inspectable {
            emitInspection(.event(
                rootId: inspectionRootId,
                actor: InspectionActorRef.from(child),
                source: inspectionActorRef,
                event: event
            ))
        }
        await child.send(event)
    }

    func cancelScheduledTimer(_ timerId: String) {
        scheduler.cancel(timerId)
    }

    private func cancelDelayedTransition(_ eventType: String) {
        cancelScheduledTimer(eventType)
    }

    /// The actor's current snapshot, exposed to `ActionEffectRunner` (the `EffectHost` seam) so the
    /// extracted dispatch can re-read it after a spawn/stop mutates it.
    var effectSnapshot: MachineSnapshot<Context>? { _snapshot }

    /// Forwards an event to this actor's parent, if any. The `EffectHost` witness for the
    /// `sendParent` action (was an inline `await parent?.enqueueFromChild(...)`).
    func enqueueToParent(_ event: any Eventable) async {
        await parent?.enqueueFromChild(event)
    }

    /// Runs a macrostep's side-effect actions. The dispatch itself lives in `ActionEffectRunner`,
    /// shared with the generics refactor's runtime; passing `host: self` (an `isolated` parameter)
    /// keeps every effect call same-actor and non-hopping, exactly as when this loop was inline.
    private func runSideEffectActions(
        snapshot: MachineSnapshot<Context>,
        actions: [ExecutableAction<Context>],
        event: any Eventable
    ) async -> MachineSnapshot<Context> {
        await ActionEffectRunner().run(
            snapshot: snapshot,
            actions: actions,
            event: event,
            machine: machine,
            host: self
        )
    }

    /// Listens for events emitted by `emit(…)` actions. Pass `"*"` for all emitted events.
    public func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }

    /// Observe every snapshot. The handler fires immediately with the current snapshot, then on
    /// each subsequent transition. Retain the returned `Subscription` and `cancel()` to stop.
    public func subscribe(_ handler: @escaping @Sendable (MachineSnapshot<Context>) -> Void) -> Subscription {
        if let snapshot = _snapshot {
            handler(snapshot)
        }
        // Key the subscription by a stable id, not an array index: cancelling an earlier
        // subscription shifts the array, so an index-based remove would drop the wrong observer.
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

    private func notify(_ snapshot: MachineSnapshot<Context>, event: any Eventable) {
        inspectSnapshot(event, snapshot: snapshot)
        for observer in observers {
            observer.handler(snapshot)
        }
    }

    func notifyEmitted(_ event: EmittedEvent) {
        emitListeners.notify(event)
    }

    public func inspectSpawnedChild(_ child: any ChildActorRef, machineId: String?) {
        emitInspection(.actor(
            rootId: inspectionRootId,
            actor: InspectionActorRef.from(child, machineId: machineId),
            parentSessionId: id,
            definitionJSON: child.definitionJSON
        ))
    }

    func childActor(id: String) -> (any ChildActorRef)? {
        childRegistry.get(id)
    }
    
}
