import Foundation

// MARK: - The inter-actor plane
//
// An `Interactor` is a Swift `actor` — the concurrency membrane that owns one or more running
// XState actors (`Actor<Context>`) and mediates *between* them and between Interactors. The
// hosted actors keep their own synchronous run-to-completion (RTC) cores; the Interactor adds the
// asynchronous plane on top: typed addressing (`ActorRef`), non-blocking routing, supervision,
// and a scoped inspection stream. Within an Interactor everything is serial and deterministic;
// across Interactors everything is async — which is exactly where Hewitt's model puts the seam.
//
// This is purely additive. The webby/XState surface (`createActor(...).send(...)`) is unchanged
// and corresponds to the degenerate case of one actor per implicit Interactor, with the membrane
// provided by the actor's own `DispatchQueue` instead of a Swift `actor`.

/// A monotonically increasing logical clock (Lamport). Cheap and thread-safe, so the
/// inspection-forwarding closure (which runs on a hosted actor's queue thread) can stamp events
/// without hopping isolation. `witness(_:)` advances past a clock observed on an inbound message,
/// preserving happens-before across the async boundary.
public final class LamportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    public init() {}

    @discardableResult
    public func tick() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }

    public func witness(_ incoming: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value = Swift.max(value, incoming) &+ 1
    }

    public var current: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// A globally-unique address for a hosted actor: which Interactor it lives in, and its id there.
public struct ActorAddress: Sendable, Equatable, Hashable, Codable {
    public let interactorID: String
    public let actorID: String

    public init(interactorID: String, actorID: String) {
        self.interactorID = interactorID
        self.actorID = actorID
    }

    /// A stable, collision-free node id for a unified graph: `interactor/actor`.
    public var qualified: String { "\(interactorID)/\(actorID)" }
}

/// An inspection event tagged with the Interactor it originated in, plus ordering metadata. This
/// is the envelope that crosses isolation boundaries and gets merged into one unified picture by
/// ``InspectionHub`` — the raw ``InspectionEvent`` is carried verbatim, so the XState-faithful
/// shape is untouched.
public struct ScopedInspectionEvent: Sendable, Identifiable {
    public enum Payload: Sendable {
        /// A normal runtime inspection event from a hosted actor (`@xstate.*`).
        case inspection(InspectionEvent)
        /// A message routed across the inter-actor plane — the cross-domain edge of the graph.
        case message(MessageEdge)
        /// A supervision/lifecycle transition the Interactor itself performed.
        case lifecycle(Lifecycle)
    }

    public struct MessageEdge: Sendable, Equatable {
        public let from: ActorAddress?
        public let to: ActorAddress
        public let event: String
        public let correlation: UUID
    }

    public struct Lifecycle: Sendable, Equatable {
        public enum Kind: String, Sendable { case spawned, stopped, restarted, crashed }
        public let kind: Kind
        public let actor: ActorAddress
        public let detail: String?
    }

    public let id: UUID
    public let interactorID: String
    /// Per-Interactor causal clock.
    public let lamport: UInt64
    /// Total order assigned at the merge point by ``InspectionHub`` (nil until merged).
    public let globalSeq: UInt64?
    public let timestamp: TimeInterval
    public let payload: Payload

    public init(
        id: UUID = UUID(),
        interactorID: String,
        lamport: UInt64,
        globalSeq: UInt64? = nil,
        timestamp: TimeInterval,
        payload: Payload
    ) {
        self.id = id
        self.interactorID = interactorID
        self.lamport = lamport
        self.globalSeq = globalSeq
        self.timestamp = timestamp
        self.payload = payload
    }

    func withGlobalSeq(_ seq: UInt64) -> ScopedInspectionEvent {
        ScopedInspectionEvent(
            id: id, interactorID: interactorID, lamport: lamport,
            globalSeq: seq, timestamp: timestamp, payload: payload
        )
    }
}

/// A thread-safe fan-out of ``ScopedInspectionEvent``. Mirrors the codebase's lock-based
/// `@unchecked Sendable` registries (see `ActorSystem`, `InspectionCollector`): emitting happens
/// on whatever thread produced the event, so it can't be actor-isolated.
public final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: @Sendable (ScopedInspectionEvent) -> Void] = [:]
    private var nextToken = 0

    public init() {}

    func emit(_ event: ScopedInspectionEvent) {
        lock.lock()
        let current = Array(sinks.values)
        lock.unlock()
        for sink in current { sink(event) }
    }

    @discardableResult
    func addSink(_ sink: @escaping @Sendable (ScopedInspectionEvent) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        sinks[token] = sink
        return token
    }

    func removeSink(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        sinks[token] = nil
    }

    /// Synchronously observe every event emitted after subscription — the handler fires on the
    /// producer's thread, so by the time a triggering `await` returns, the event is already in
    /// hand (handy for deterministic collection/tests). Returns a `Subscription`; `cancel()` to
    /// stop. For async iteration, prefer ``stream()``.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (ScopedInspectionEvent) -> Void) -> Subscription {
        let token = addSink(handler)
        return Subscription { [weak self] in self?.removeSink(token) }
    }

    /// A live stream of every event emitted after subscription. Cancelling the consuming task
    /// removes the sink.
    public func stream() -> AsyncStream<ScopedInspectionEvent> {
        AsyncStream { continuation in
            let token = addSink { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in self?.removeSink(token) }
        }
    }
}

/// What an Interactor should do when a hosted actor reaches a designated failure state.
public enum RestartStrategy: Sendable, Equatable {
    /// Leave the actor where it is (default — supervision is opt-in).
    case stop
    /// Tear down and recreate the actor when its state matches `state`, restarting from initial.
    case restartOnState(String)
}

// MARK: - Type-erased hosted actor

/// Interactor-isolated box over a generic `Actor<Context>`. Only ever touched on the owning
/// Interactor's executor; the inspection-forwarding closure it installs captures only `Sendable`
/// values (the bus, the clock, ids), never the box.
protocol AnyHosted: AnyObject, Sendable {
    var actorID: String { get }
    func post(_ event: any Eventable)
    func stop()
    func restart()
    func currentStateValue() -> String
    /// A stream that yields whenever the *current* actor instance enters `state`. Only the yields
    /// (`Void`) cross threads; the box itself is never touched off the Interactor's executor.
    func failureSignals(matching state: String) -> AsyncStream<Void>
}

final class Hosted<Context: Sendable>: AnyHosted, @unchecked Sendable {
    let actorID: String
    let machine: StateMachine<Context>
    let inspect: @Sendable (InspectionEvent) -> Void
    private(set) var actor: Actor<Context>

    init(
        actorID: String,
        machine: StateMachine<Context>,
        actor: Actor<Context>,
        inspect: @escaping @Sendable (InspectionEvent) -> Void
    ) {
        self.actorID = actorID
        self.machine = machine
        self.actor = actor
        self.inspect = inspect
    }

    func post(_ event: any Eventable) { actor.post(event) }
    func stop() { actor.stop() }

    func restart() {
        actor.stop()
        actor = createActor(machine, id: actorID, options: ActorOptions(inspect: inspect)).start()
    }

    func currentStateValue() -> String { actor.snapshot.value.description }
    func snapshot() -> MachineSnapshot<Context> { actor.snapshot }

    func failureSignals(matching state: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let subscription = actor.subscribe { snapshot in
                if snapshot.matches(state) { continuation.yield(()) }
            }
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }
}

// MARK: - ActorRef

/// A `Sendable`, typed handle to an actor hosted by an ``Interactor`` — the inter-actor *address*.
/// Sends are asynchronous and routed through the owning Interactor, so a ref works the same
/// whether the target lives in the same Interactor or a peer (location transparency). The event
/// argument is a concrete ``StateEvent`` value, so messaging stays string-free and compiler-checked.
public struct ActorRef<Context: Sendable>: Sendable {
    public let id: String
    public let interactorID: String
    let interactor: Interactor

    public var address: ActorAddress { ActorAddress(interactorID: interactorID, actorID: id) }

    /// Deliver a typed event. Non-blocking and FIFO-ordered at the target's mailbox.
    public func send(_ event: some Eventable) async {
        await interactor.route(event, to: id, from: nil)
    }

    /// Deliver a typed event, attributing it to a sending actor `from` — typically another
    /// Interactor's actor. The attribution surfaces as a cross-domain edge in the unified graph.
    public func send(_ event: some Eventable, from source: ActorAddress) async {
        await interactor.route(event, to: id, from: source)
    }

    /// Read the current typed snapshot (state value, context, tags). `nil` if the actor is gone.
    public func snapshot() async -> MachineSnapshot<Context>? {
        await interactor.snapshot(of: id, as: Context.self)
    }

    /// Supervised restart: tear the actor down and recreate it from its initial state.
    public func restart() async {
        await interactor.restart(actorID: id)
    }
}

// MARK: - Interactor

/// A concurrency membrane that owns a tree of XState actors and connects them to the async world.
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

    /// Build, start, and host an actor from a machine. Returns a typed ``ActorRef``. Inspection is
    /// wired at creation time, so the actor's registration event is captured.
    @discardableResult
    public func spawn<Context: Sendable>(
        _ machine: StateMachine<Context>,
        id requestedID: String? = nil,
        supervision: RestartStrategy = .stop
    ) -> ActorRef<Context> {
        let actorID = uniqueID(requestedID ?? machine.id)
        let inspect = makeInspect(forActor: actorID)
        let actor = createActor(machine, id: actorID, options: ActorOptions(inspect: inspect)).start()
        let box = Hosted(actorID: actorID, machine: machine, actor: actor, inspect: inspect)
        hosted[actorID] = box
        emitLifecycle(.spawned, actorID: actorID, detail: machine.id)

        if case let .restartOnState(state) = supervision {
            installSupervisor(actorID: actorID, restartWhen: state)
        }

        return ActorRef(id: actorID, interactorID: id, interactor: self)
    }

    // MARK: Routing

    /// Route a message to a hosted actor. Emits a cross-domain message edge for the unified graph,
    /// then delivers non-blocking. `from` is set when the send is attributed to another actor
    /// (e.g. an actor in a different Interactor), which is what draws the inter-domain edge.
    func route(_ event: any Eventable, to actorID: String, from source: ActorAddress?) {
        let edge = ScopedInspectionEvent.MessageEdge(
            from: source,
            to: ActorAddress(interactorID: id, actorID: actorID),
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

    private func makeInspect(forActor actorID: String) -> @Sendable (InspectionEvent) -> Void {
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
            actor: ActorAddress(interactorID: id, actorID: actorID),
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
