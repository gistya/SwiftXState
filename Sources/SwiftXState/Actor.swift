import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// Options for creating an actor — clock, system id, input, and inspection wiring.
public struct ActorOptions: Sendable {
    /// Clock used for `after:` delays and delayed `raise`/`sendTo` (override in tests).
    public var clock: any Clock
    /// Stable id for this actor within its actor system (for `sendTo`/`stateIn` references).
    public var systemId: String?
    /// Input passed to the machine's `contextFromInput` to build the initial context.
    public var input: SendableValue?
    /// Sink for this actor's inspection events — plug in `InspectorStore.observe()` or a transport.
    public var inspect: (@Sendable (InspectionEvent) -> Void)?
    /// When `false`, this actor does not emit inspection events (Stately graph / sequence).
    public var inspectable: Bool
    /// When `true`, this actor runs on the `MainActor`'s serial executor instead of its own default
    /// (background) executor. This eliminates the thread hop for `send`/`snapshot` calls made *from*
    /// the main actor — useful for latency-sensitive UI — at the cost of running the actor's work on
    /// the main thread. Has no effect on platforms without `Darwin` (the override is Apple-only).
    public var useMainExecutor: Bool

    public init(
        clock: any Clock = DefaultClock(),
        systemId: String? = nil,
        input: SendableValue? = nil,
        inspect: (@Sendable (InspectionEvent) -> Void)? = nil,
        inspectable: Bool = true,
        useMainExecutor: Bool = false
    ) {
        self.clock = clock
        self.systemId = systemId
        self.input = input
        self.inspect = inspect
        self.inspectable = inspectable
        self.useMainExecutor = useMainExecutor
    }
}

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
    private var scheduledTimers: [String: TimeoutHandle] = [:]
    private var children: [String: any ChildActorRef] = [:]
    private var stoppedChildIDs: Set<String> = []
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
    private nonisolated let system: ActorSystem
    private nonisolated let options: ActorOptions
    private nonisolated let inspectable: Bool
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
        self.clock = options.clock
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

    private func emitInspection(_ event: InspectionEvent) {
        guard inspectable else { return }
        system.sendInspection(event)
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
            guard let child = children[childId] else { return false }
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
        guard let actorId, let child = children[actorId] else { return nil }
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
        let childSnapshots = try await collectPersistedChildSnapshots(from: children)
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
            isInitial: false
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
                    children[invoke.id] = child
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

    private func spawnFromAction(_ spawn: SpawnRef<Context>, args: ActionArgs<Context>) async {
        let childId = spawn.id ?? UUID().uuidString
        guard children[childId] == nil else { return }
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
            children[childId] = child
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

    private func stopChild(id: String) async {
        guard let child = children.removeValue(forKey: id) else { return }
        stoppedChildIDs.insert(id)
        system.unregister(child)
        await child.stop()
        syncChildrenSnapshot()
    }

    private func stopAllChildren() async {
        stoppedChildIDs.formUnion(children.keys)
        for child in children.values {
            system.unregister(child)
            await child.stop()
        }
        children.removeAll()
    }

    private func syncChildrenSnapshot() {
        guard var snapshot = _snapshot else { return }
        stoppedChildIDs.subtract(children.keys)
        var childSnapshots = children.mapValues {
            ChildActorSnapshot(
                id: $0.id,
                status: $0.status,
                value: $0.snapshotValue,
                error: $0.errorMessage
            )
        }
        for (id, existing) in snapshot.children where childSnapshots[id] == nil && !stoppedChildIDs.contains(id) {
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

    private func scheduleDelayedTransition(eventType: String, delay: Int, timerId: String) {
        cancelScheduledTimer(timerId)

        let handle = clock.setTimeout({ [weak self] in
            Task { await self?.sendDelayed(Event(eventType), timerId: timerId) }
        }, delay: delay)
        scheduledTimers[timerId] = handle
    }

    private func scheduleDelayedSendTo(
        childId: String,
        event: Event,
        delay: Int,
        timerId: String
    ) {
        cancelScheduledTimer(timerId)

        let handle = clock.setTimeout({ [weak self] in
            Task { await self?.sendDelayedToChild(childId: childId, event: event, timerId: timerId) }
        }, delay: delay)
        scheduledTimers[timerId] = handle
    }

    private func sendDelayed(_ event: Event, timerId: String) async {
        scheduledTimers.removeValue(forKey: timerId)
        inspectIncomingEvent(event, source: nil)
        mailbox.append(event)
        await drain()
    }

    private func sendDelayedToChild(childId: String, event: Event, timerId: String) async {
        scheduledTimers.removeValue(forKey: timerId)
        await deliverToChild(id: childId, event: event)
    }

    private func deliverToChild(id childId: String, event: any Eventable) async {
        guard let child = children[childId] else { return }
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

    private func cancelScheduledTimer(_ timerId: String) {
        guard let handle = scheduledTimers.removeValue(forKey: timerId) else { return }
        clock.clearTimeout(handle)
    }

    private func cancelDelayedTransition(_ eventType: String) {
        cancelScheduledTimer(eventType)
    }

    private func runSideEffectActions(
        snapshot: MachineSnapshot<Context>,
        actions: [ExecutableAction<Context>],
        event: any Eventable
    ) async -> MachineSnapshot<Context> {
        var context = snapshot.context
        var result = snapshot

        for action in actions {
            switch action.ref {
            case .assign:
                continue
            case .named, .parameterized, .inline, .log:
                let args = ActionArgs(context: context, event: event)
                executeAction(action, context: &context, args: args, implementations: machine.implementations)
            case let .emit(emitAction):
                let args = ActionArgs(context: context, event: event)
                notifyEmitted(resolveEmitEvent(emitAction, args: args))
            case let .spawn(spawn):
                let args = ActionArgs(context: context, event: event)
                await spawnFromAction(spawn, args: args)
                result = _snapshot ?? result
            case let .stopChild(target):
                let args = ActionArgs(context: context, event: event)
                await stopChild(id: resolveChildTarget(target, args: args))
                result = _snapshot ?? result
            case let .forwardTo(target):
                let args = ActionArgs(context: context, event: event)
                await deliverToChild(id: resolveChildTarget(target, args: args), event: event)
            case let .sendTo(sendToAction):
                let args = ActionArgs(context: context, event: event)
                let resolved = resolveSendTo(
                    sendToAction,
                    args: args,
                    delays: machine.implementations.delays
                )
                if let delayMs = resolved.delayMs {
                    scheduleDelayedSendTo(
                        childId: resolved.childId,
                        event: resolved.event,
                        delay: delayMs,
                        timerId: resolved.id ?? "sendTo.\(resolved.childId).\(resolved.event.type)"
                    )
                } else {
                    await deliverToChild(id: resolved.childId, event: resolved.event)
                }
            case let .sendParent(parentEvent):
                await parent?.enqueueFromChild(parentEvent)
            case .raise:
                if let delayedEvent = action.delayedEvent,
                   let delayMs = action.delayMs,
                   let timerId = action.timerId {
                    scheduleDelayedTransition(
                        eventType: delayedEvent.type,
                        delay: delayMs,
                        timerId: timerId
                    )
                }
            case let .cancel(cancelId):
                let args = ActionArgs(context: context, event: event)
                cancelScheduledTimer(resolveCancelId(cancelId, args: args))
            case .enqueueActions:
                break
            }
        }

        return MachineSnapshot(
            machine: result.machine,
            value: result.value,
            context: context,
            nodes: result._nodes,
            tags: result.tags,
            status: result.status,
            historyValue: result.historyValue,
            output: result.output,
            error: result.error,
            children: result.children
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

    private func notifyEmitted(_ event: EmittedEvent) {
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
        children[id]
    }
}

/// Creates an actor (a runnable instance) from a machine — the Swift equivalent of XState's
/// `createActor(machine)`. Call `.start()` on the result to run it. Pass `inspect:` to stream
/// inspection events, or `input:` to seed the initial context via `contextFromInput`.
public func createActor<Context: Sendable>(
    _ machine: StateMachine<Context>,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    input: SendableValue? = nil,
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> Actor<Context> {
    var resolvedOptions = options
    if let input {
        resolvedOptions.input = input
    }
    if let inspect {
        resolvedOptions.inspect = inspect
    }
    return Actor(machine, id: id, options: resolvedOptions)
}

/// Creates an actor branded with a compile-time state family `Brand`, returning a `TypedActor`
/// whose `snapshot` / `start` / `send` yield `Brand`-typed `TypedSnapshot`s (`inState(_:)` /
/// `narrowed(to:)`). Brand at creation instead of the post-hoc `createActor(machine).typed(as:)`
/// two-step; otherwise identical to `createActor(_:)`.
public func createActor<Context: Sendable, Brand: StateID>(
    _ machine: StateMachine<Context>,
    as _: Brand.Type,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    input: SendableValue? = nil,
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> TypedActor<Context, Brand> {
    TypedActor(createActor(machine, id: id, options: options, input: input, inspect: inspect))
}

/// Creates an actor and hydrates it from a persisted snapshot in one step.
///
/// The returned actor is already started — equivalent to
/// `createActor(machine).start(from: snapshot)`, including child re-spawn and
/// delayed-transition scheduling for restored state nodes.
public func createActor<Context: Codable & Sendable>(
    _ machine: StateMachine<Context>,
    snapshot: PersistedSnapshot,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    context: Context? = nil,
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) async -> Actor<Context> {
    var resolvedOptions = options
    if let inspect {
        resolvedOptions.inspect = inspect
    }
    let actor = Actor(machine, id: id, options: resolvedOptions)
    await actor.start(from: snapshot, context: context)
    return actor
}

/// Brand-tagged variant of `createActor(_:snapshot:)`; the hydrated actor is wrapped in a
/// `Brand`-typed `TypedActor`.
public func createActor<Context: Codable & Sendable, Brand: StateID>(
    _ machine: StateMachine<Context>,
    as _: Brand.Type,
    snapshot: PersistedSnapshot,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    context: Context? = nil,
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) async -> TypedActor<Context, Brand> {
    TypedActor(
        await createActor(
            machine,
            snapshot: snapshot,
            id: id,
            options: options,
            context: context,
            inspect: inspect
        )
    )
}

/// Creates an actor with typed `input` (any `Sendable & Equatable`), wrapped into the machine's
/// `contextFromInput`. Convenience over passing a `SendableValue`.
public func createActor<Context: Sendable, Input: Sendable & Equatable>(
    _ machine: StateMachine<Context>,
    input: Input,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> Actor<Context> {
    createActor(
        machine,
        id: id,
        options: options,
        input: SendableValue(input),
        inspect: inspect
    )
}

/// Brand-tagged variant of `createActor(_:input:)`.
public func createActor<Context: Sendable, Input: Sendable & Equatable, Brand: StateID>(
    _ machine: StateMachine<Context>,
    as _: Brand.Type,
    input: Input,
    id: String? = nil,
    options: ActorOptions = ActorOptions(),
    inspect: (@Sendable (InspectionEvent) -> Void)? = nil
) -> TypedActor<Context, Brand> {
    TypedActor(createActor(machine, input: input, id: id, options: options, inspect: inspect))
}

/// A handle returned by `Actor.subscribe(_:)`. Call `cancel()` to stop receiving snapshots.
public struct Subscription: Sendable {
    private let unsubscribe: @Sendable () -> Void

    init(unsubscribe: @escaping @Sendable () -> Void) {
        self.unsubscribe = unsubscribe
    }

    /// Stop receiving snapshot updates.
    public func cancel() {
        unsubscribe()
    }
}
