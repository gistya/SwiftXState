import Foundation

/// A concurrency membrane that owns a tree of XState reactors and connects them to the async world.
///
/// An `Interactor` is a Swift `reactor` — the concurrency membrane that owns one or more running
/// XState reactors (`Reactor<Context>`) and mediates *between* them and between Interactors. The
/// hosted reactors keep their own synchronous run-to-completion (RTC) cores; the Interactor adds the
/// asynchronous plane on top: typed addressing (`ReactorRef`), non-blocking routing, supervision,
/// and a scoped inspection stream. Within an Interactor everything is serial and deterministic;
/// across Interactors everything is async — which is exactly where Hewitt's model puts the seam.
/// An `Interactor` is a Swift `reactor` — the concurrency membrane that owns one or more running
/// XState reactors (`Reactor<Context>`) and mediates *between* them and between Interactors. The
/// hosted reactors keep their own synchronous run-to-completion (RTC) cores; the Interactor adds the
/// asynchronous plane on top: typed addressing (`ReactorRef`), non-blocking routing, supervision,
public actor Interactor {
    /// Stable id, used to namespace this Interactor's reactors in the unified picture.
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

    /// Build, start, and host an reactor from a machine. Returns a typed ``ReactorRef``. Inspection is
    /// wired at creation time, so the reactor's registration event is captured.
    @discardableResult
    public func spawn<Context: Sendable>(
        _ machine: StateMachine<Context>,
        id requestedID: String? = nil,
        supervision: RestartStrategy = .stop
    ) -> ReactorRef<Context> {
        let reactorID = uniqueID(requestedID ?? machine.id)
        let inspect = makeInspect(forReactor: reactorID)
        let reactor = createReactor(machine, id: reactorID, options: ReactorOptions(inspect: inspect)).start()
        let box = Hosted(reactorID: reactorID, machine: machine, reactor: reactor, inspect: inspect)
        hosted[reactorID] = box
        emitLifecycle(.spawned, reactorID: reactorID, detail: machine.id)

        if case let .restartOnState(state) = supervision {
            installSupervisor(reactorID: reactorID, restartWhen: state)
        }

        return ReactorRef(id: reactorID, interactorID: id, interactor: self)
    }

    // MARK: Routing

    /// Route a message to a hosted reactor. Emits a cross-domain message edge for the unified graph,
    /// then delivers non-blocking. `from` is set when the send is attributed to another reactor
    /// (e.g. an reactor in a different Interactor), which is what draws the inter-domain edge.
    func route(_ event: any Eventable, to reactorID: String, from source: ReactorAddress?) {
        let edge = ScopedInspectionEvent.MessageEdge(
            from: source,
            to: ReactorAddress(interactorID: id, reactorID: reactorID),
            event: event.type,
            correlation: UUID()
        )
        emit(.message(edge))
        hosted[reactorID]?.post(event)
    }

    // MARK: Reads & lifecycle

    func snapshot<Context: Sendable>(of reactorID: String, as _: Context.Type) -> MachineSnapshot<Context>? {
        (hosted[reactorID] as? Hosted<Context>)?.snapshot()
    }

    /// Current state value of a hosted reactor, type-erased — handy for dashboards.
    public func stateValue(of reactorID: String) -> String? {
        hosted[reactorID]?.currentStateValue()
    }

    public func restart(reactorID: String) {
        guard let box = hosted[reactorID] else { return }
        box.restart()
        emitLifecycle(.restarted, reactorID: reactorID, detail: nil)
    }

    /// Stop a single reactor and forget it.
    public func stop(reactorID: String) {
        guard let box = hosted[reactorID] else { return }
        supervisors.removeValue(forKey: reactorID)?.cancel()
        box.stop()
        hosted.removeValue(forKey: reactorID)
        emitLifecycle(.stopped, reactorID: reactorID, detail: nil)
    }

    /// Stop every hosted reactor — the supervisor shutting down its domain.
    public func stopAll() {
        for id in Array(hosted.keys) { stop(reactorID: id) }
    }

    public var reactorIDs: [String] { Array(hosted.keys).sorted() }

    // MARK: - Internals

    private func uniqueID(_ base: String) -> String {
        guard hosted[base] != nil else { return base }
        counter += 1
        return "\(base)#\(counter)"
    }

    private func makeInspect(forReactor reactorID: String) -> @Sendable (InspectionEvent) -> Void {
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
        reactorID: String,
        detail: String?
    ) {
        emit(.lifecycle(.init(
            kind: kind,
            reactor: ReactorAddress(interactorID: id, reactorID: reactorID),
            detail: detail
        )))
    }

    /// Watches a hosted reactor and restarts it whenever it enters `state`. The loop re-subscribes to
    /// the *current* reactor instance each iteration (via the isolated ``failureStream(reactorID:state:)``),
    /// so it keeps supervising across restarts with no fragile type-erased re-arm. All box mutation
    /// stays on this Interactor's executor — only `Void` yields cross to the `Task` — so a restart
    /// never races a `route`/`snapshot` nor re-enters the reactor synchronously.
    private func installSupervisor(reactorID: String, restartWhen state: String) {
        supervisors[reactorID]?.cancel()
        supervisors[reactorID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let stream = await self.failureStream(reactorID: reactorID, state: state)
                else { return }
                var fired = false
                for await _ in stream { fired = true; break }
                guard fired, !Task.isCancelled else { return }
                await self.superviseRestart(reactorID: reactorID, reason: state)
            }
        }
    }

    /// Isolated: subscribe to the current reactor instance and surface its failure-state entries.
    private func failureStream(reactorID: String, state: String) -> AsyncStream<Void>? {
        hosted[reactorID]?.failureSignals(matching: state)
    }

    /// Isolated: the actual restart, so `box` is mutated only on this Interactor's executor.
    private func superviseRestart(reactorID: String, reason: String) {
        guard let box = hosted[reactorID] else { return }
        emitLifecycle(.crashed, reactorID: reactorID, detail: reason)
        box.restart()
        emitLifecycle(.restarted, reactorID: reactorID, detail: "after \(reason)")
    }
}
