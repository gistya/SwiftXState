import Foundation

/// **Experimental — generics refactor.** The new actor runtime, assembled entirely from the pieces
/// carved out of `Actor`: `DelayScheduler` (timers), `ChildRegistry` (children), `ActionEffectRunner`
/// (effect dispatch, reached via `EffectHost`), and the free `makeChildActorRef` child factory — all
/// over the pure engine (`initialTransition` / `macrostep`). Its job is to *prove* that shared
/// runtime is sufficient to reach feature parity with `Actor` (transition, `always`, `after`,
/// `sendTo`, `emit`, `cancel`, `spawn`, `invoke`, `stopChild`, `forwardTo`) before `Actor` is
/// retired in its favour.
///
/// This is the machine-specialized shape — the eventual `StateActor<Logic, ID>` reduced to the
/// `MachineLogic` case, since the `after`/`invoke` orchestration is intrinsically machine-shaped.
/// Inspection, persistence/restore, and custom executors are deliberately omitted: they are
/// orthogonal to the effect/child parity this vehicle establishes, and reusing the same shared
/// pieces, they add nothing to the proof.
///
/// Spawned children are still created by the shared factory, so a sub-machine child is a regular
/// `Actor`; its `sendParent` lands back here via `enqueueFromChild`. The point isn't that children
/// are `StateActor`s yet — it's that `StateActor` *orchestrates* spawn/invoke identically.
actor StateActor<Context: Sendable>: ActorParentRef, ActorSystemRef, EffectHost {
    private var _snapshot: MachineSnapshot<Context>?
    private var mailbox: [any Eventable] = []
    /// See `Actor.isProcessing`: a child's `sendParent` arriving mid-`processEvent` must queue, not
    /// reenter and clobber `_snapshot`.
    private var isProcessing = false
    private let emitListeners = EmitListeners()
    private var observers: [(id: Int, handler: @Sendable (MachineSnapshot<Context>) -> Void)] = []
    private var nextObserverID = 0
    private let childRegistry = ChildRegistry()
    private let scheduler: DelayScheduler
    private weak var parent: (any ActorParentRef)?
    private nonisolated let system: ActorSystem
    private nonisolated let clock: any Clock
    private nonisolated let options: ActorOptions
    private let logic: MachineLogic<Context>

    let machine: StateMachine<Context>
    nonisolated let id: String

    nonisolated var actorSystem: ActorSystem { system }
    nonisolated var sessionId: String { id }
    nonisolated var systemId: String? { options.systemId }

    var status: SnapshotStatus { _snapshot?.status ?? .stopped }

    /// The current snapshot. Traps if the actor hasn't been started, matching `Actor.snapshot`.
    var snapshot: MachineSnapshot<Context> {
        guard let snapshot = _snapshot else {
            fatalError("StateActor has not been started. Call start() first.")
        }
        return snapshot
    }

    init(
        _ machine: StateMachine<Context>,
        id: String? = nil,
        options: ActorOptions = ActorOptions(),
        parent: (any ActorParentRef)? = nil,
        system: ActorSystem? = nil
    ) {
        self.machine = machine
        self.logic = MachineLogic(machine: machine)
        self.id = id ?? machine.id
        self.options = options
        self.clock = options.clock
        self.scheduler = DelayScheduler(clock: options.clock)
        self.parent = parent
        self.system = system ?? parent?.actorSystem ?? ActorSystem()
        if parent == nil {
            self.system.setRootIdIfNeeded(self.id)
        }
    }

    // MARK: Lifecycle

    @discardableResult
    func start(input: SendableValue? = nil, context: Context? = nil) async -> Self {
        // Startup is one processing cycle (see `isProcessing`): entry-action sends to children that
        // bounce back via `sendParent` queue and drain in order rather than reentering.
        isProcessing = true
        defer { isProcessing = false }
        let resolvedInput = input ?? options.input
        let (snapshot, actions) = logic.initialSnapshot(input: resolvedInput, context: context)
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
        notify(_snapshot!)
        return self
    }

    func stop() async {
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
        }
    }

    // MARK: Event intake

    func send(_ event: any Eventable) async {
        mailbox.append(event)
        await drain()
    }

    func enqueueFromChild(_ event: any Eventable) async {
        mailbox.append(event)
        await drain()
    }

    /// Listens for `emit(…)` events, like `Actor.on`. `"*"` matches all.
    @discardableResult
    func on(_ eventType: String, handler: @escaping @Sendable (EmittedEvent) -> Void) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }

    func inspectSpawnedChild(_ child: any ChildActorRef, machineId: String?) async {
        // Inspection is deferred for the experimental runtime (see type doc).
    }

    /// Observe every settled snapshot. Fires immediately with the current snapshot, then on each
    /// transition — matching `Actor.subscribe`, so the same `waitForSnapshot` pattern works here.
    @discardableResult
    func subscribe(_ handler: @escaping @Sendable (MachineSnapshot<Context>) -> Void) -> Subscription {
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

    private func notify(_ snapshot: MachineSnapshot<Context>) {
        for observer in observers {
            observer.handler(snapshot)
        }
    }

    // MARK: Run-to-completion

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
            fatalError("StateActor has not been started. Call start() first.")
        }
        guard current.status == .active else { return }

        let previousNodes = current._nodes
        let (nextSnapshot, actions) = logic.reduce(current, on: event)
        _snapshot = await runSideEffectActions(snapshot: nextSnapshot, actions: actions, event: event)

        let previousSet = StateNodeSet(previousNodes)
        let newSet = StateNodeSet(_snapshot!._nodes)
        var entered = StateNodeSet<Context>()
        var exited = StateNodeSet<Context>()
        for node in newSet where !previousSet.contains(node) { entered.insert(node) }
        for node in previousSet where !newSet.contains(node) { exited.insert(node) }

        updateDelayedTransitions(entered: entered, exited: exited, snapshot: _snapshot!, event: event)
        await updateChildActors(entered: entered, exited: exited, snapshot: _snapshot!, event: event)
        notify(_snapshot!)
    }

    // MARK: after / invoke orchestration

    private func updateDelayedTransitions(
        entered: StateNodeSet<Context>,
        exited: StateNodeSet<Context>,
        snapshot: MachineSnapshot<Context>,
        event: any Eventable
    ) {
        for node in exited {
            for schedule in node.afterSchedules {
                cancelScheduledTimer(schedule.eventType)
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
                    persistedChild: nil,
                    opaqueRestorePolicy: invoke.opaqueRestorePolicy
                ) {
                    childRegistry.add(invoke.id, child)
                    system.register(child)
                    await child.start()
                }
            }
        }
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

    // MARK: Delayed-timer callbacks

    private func sendDelayed(_ event: Event, timerId: String) async {
        scheduler.didFire(timerId)
        mailbox.append(event)
        await drain()
    }

    private func sendDelayedToChild(childId: String, event: Event, timerId: String) async {
        scheduler.didFire(timerId)
        await deliverToChild(id: childId, event: event)
    }

    // MARK: EffectHost

    var effectSnapshot: MachineSnapshot<Context>? { _snapshot }

    func notifyEmitted(_ event: EmittedEvent) {
        emitListeners.notify(event)
    }

    func enqueueToParent(_ event: any Eventable) async {
        await parent?.enqueueFromChild(event)
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
            persistedChild: nil,
            opaqueRestorePolicy: spawn.opaqueRestorePolicy
        ) {
            childRegistry.add(childId, child)
            system.register(child)
            await child.start()
        }
        syncChildrenSnapshot()
    }

    func stopChild(id: String) async {
        guard let child = childRegistry.remove(id) else { return }
        childRegistry.markStopped(id)
        system.unregister(child)
        await child.stop()
        syncChildrenSnapshot()
    }

    func deliverToChild(id childId: String, event: any Eventable) async {
        guard let child = childRegistry.get(childId) else { return }
        await child.send(event)
    }

    func scheduleDelayedSendTo(childId: String, event: Event, delay: Int, timerId: String) {
        scheduler.schedule(timerId, delay: delay) { [weak self] in
            Task { await self?.sendDelayedToChild(childId: childId, event: event, timerId: timerId) }
        }
    }

    func scheduleDelayedTransition(eventType: String, delay: Int, timerId: String) {
        scheduler.schedule(timerId, delay: delay) { [weak self] in
            Task { await self?.sendDelayed(Event(eventType), timerId: timerId) }
        }
    }

    func cancelScheduledTimer(_ timerId: String) {
        scheduler.cancel(timerId)
    }

    // MARK: Wrapper

    /// Runs a macrostep's side effects through the shared `ActionEffectRunner`. `host: self` is an
    /// `isolated` parameter, so the dispatch executes inside this actor's isolation — same-actor,
    /// non-hopping, identical to `Actor`'s path.
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
}
