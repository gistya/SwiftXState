import Foundation

/// A concurrency membrane that owns a tree of XState actors and connects them to the async world.
///
/// An `Interactor` is a Swift `actor` — the concurrency membrane that owns one or more running
/// XState actors (`Actor<Context>`) and mediates *between* them and between Interactors. The
/// hosted actors keep their own synchronous run-to-completion (RTC) cores; the Interactor adds the
/// asynchronous plane on top: typed addressing (`ReactorRef`), non-blocking routing, supervision,
/// and a scoped inspection stream. Within an Interactor everything is serial and deterministic;
/// across Interactors everything is async — which is exactly where Hewitt's model puts the seam.
/// An `Interactor` is a Swift `actor` — the concurrency membrane that owns one or more running
/// XState actors (`Actor<Context>`) and mediates *between* them and between Interactors. The
/// hosted actors keep their own synchronous run-to-completion (RTC) cores; the Interactor adds the
/// asynchronous plane on top: typed addressing (`ReactorRef`), non-blocking routing, supervision,
public actor Interactor {
    /// Stable id, used to namespace this Interactor's actors in the unified picture.
    public nonisolated let id: String
    /// This Interactor's local inspection fan-out. Attach it to an ``InspectionHub`` to merge it
    /// with peers, or consume `bus.stream()` directly to observe just this domain.
    public nonisolated let bus = EventBus()
    private nonisolated let clock = LamportClock()

    private var hosted: [String: any AnyHosted] = [:]
    private var supervisors: [String: Task<Void, Never>] = [:]
    private var counter = 0

    public init(id: String) {
        self.id = id
    }

    // MARK: Spawning

    /// Build, start, and host an actor from a machine. Returns a typed ``ReactorRef``. Inspection is
    /// wired at creation time, so the actor's registration event is captured.
    @discardableResult
    public func spawn<Context: Sendable>(
        _ machine: StateMachine<Context>,
        id requestedID: String? = nil,
        supervision: RestartStrategy = .stop
    ) -> ReactorRef<Context> {
        let actorID = uniqueID(requestedID ?? machine.id)
        let inspect = makeInspect(forReactor: actorID)
        let actor = createReactor(machine, id: actorID, options: ReactorOptions(inspect: inspect)).start()
        let box = Hosted(actorID: actorID, machine: machine, actor: actor, inspect: inspect)
        hosted[actorID] = box
        emitLifecycle(.spawned, actorID: actorID, detail: machine.id)

        if case let .restartOnState(state) = supervision {
            installSupervisor(actorID: actorID, restartWhen: state)
        }

        return ReactorRef(id: actorID, interactorID: id, interactor: self)
    }

    // MARK: Routing

    /// Route a message to a hosted actor. Emits a cross-domain message edge for the unified graph,
    /// then delivers non-blocking. `from` is set when the send is attributed to another actor
    /// (e.g. an actor in a different Interactor), which is what draws the inter-domain edge.
    func route(_ event: any Eventable, to actorID: String, from source: ReactorAddress?) {
        let edge = ScopedInspectionEvent.MessageEdge(
            from: source,
            to: ReactorAddress(interactorID: id, actorID: actorID),
            event: event.type,
            correlation: UUID()
        )
        emit(.message(edge))
        hosted[actorID]?.post(event)
    }

    // MARK: Reads & lifecycle

    func snapshot<Context: Sendable>(of actorID: String, as _: Context.Type) -> MachineSnapshot<Context>? {
        (hosted[actorID] as? Hosted<Context>)?.snapshot()
    }

    /// Current state value of a hosted actor, type-erased — handy for dashboards.
    public func stateValue(of actorID: String) -> String? {
        hosted[actorID]?.currentStateValue()
    }

    public func restart(actorID: String) {
        guard let box = hosted[actorID] else { return }
        box.restart()
        emitLifecycle(.restarted, actorID: actorID, detail: nil)
    }

    /// Stop a single actor and forget it.
    public func stop(actorID: String) {
        guard let box = hosted[actorID] else { return }
        supervisors.removeValue(forKey: actorID)?.cancel()
        box.stop()
        hosted.removeValue(forKey: actorID)
        emitLifecycle(.stopped, actorID: actorID, detail: nil)
    }

    /// Stop every hosted actor — the supervisor shutting down its domain.
    public func stopAll() {
        for id in Array(hosted.keys) { stop(actorID: id) }
    }

    public var actorIDs: [String] { Array(hosted.keys).sorted() }

    // MARK: - Internals

    private func uniqueID(_ base: String) -> String {
        guard hosted[base] != nil else { return base }
        counter += 1
        return "\(base)#\(counter)"
    }

    private func makeInspect(forReactor actorID: String) -> @Sendable (InspectionEvent) -> Void {
        let bus = self.bus
        let clock = self.clock
        let interactorID = self.id
        return { event in
            bus.emit(ScopedInspectionEvent(
                interactorID: interactorID,
                lamport: clock.tick(),
                timestamp: event.timestamp,
                payload: .inspection(event)
            ))
        }
    }

    private func emit(_ payload: ScopedInspectionEvent.Payload) {
        bus.emit(ScopedInspectionEvent(
            interactorID: id,
            lamport: clock.tick(),
            timestamp: Date().timeIntervalSince1970,
            payload: payload
        ))
    }

    private func emitLifecycle(
        _ kind: ScopedInspectionEvent.Lifecycle.Kind,
        actorID: String,
        detail: String?
    ) {
        emit(.lifecycle(.init(
            kind: kind,
            actor: ReactorAddress(interactorID: id, actorID: actorID),
            detail: detail
        )))
    }

    /// Watches a hosted actor and restarts it whenever it enters `state`. The loop re-subscribes to
    /// the *current* actor instance each iteration (via the isolated ``failureStream(actorID:state:)``),
    /// so it keeps supervising across restarts with no fragile type-erased re-arm. All box mutation
    /// stays on this Interactor's executor — only `Void` yields cross to the `Task` — so a restart
    /// never races a `route`/`snapshot` nor re-enters the actor synchronously.
    private func installSupervisor(actorID: String, restartWhen state: String) {
        supervisors[actorID]?.cancel()
        supervisors[actorID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let stream = await self.failureStream(actorID: actorID, state: state)
                else { return }
                var fired = false
                for await _ in stream { fired = true; break }
                guard fired, !Task.isCancelled else { return }
                await self.superviseRestart(actorID: actorID, reason: state)
            }
        }
    }

    /// Isolated: subscribe to the current actor instance and surface its failure-state entries.
    private func failureStream(actorID: String, state: String) -> AsyncStream<Void>? {
        hosted[actorID]?.failureSignals(matching: state)
    }

    /// Isolated: the actual restart, so `box` is mutated only on this Interactor's executor.
    private func superviseRestart(actorID: String, reason: String) {
        guard let box = hosted[actorID] else { return }
        emitLifecycle(.crashed, actorID: actorID, detail: reason)
        box.restart()
        emitLifecycle(.restarted, actorID: actorID, detail: "after \(reason)")
    }
}
