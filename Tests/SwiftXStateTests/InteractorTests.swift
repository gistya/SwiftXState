import Testing
import Foundation
@testable import SwiftXState

// MARK: - Typed machines (no strings: events are types, targets come from @MachineStates)

private enum Toggle {
    struct Flip: StateEvent, Equatable { static let eventType = "FLIP" }

    @MachineStates("S")
    static let config = MachineConfig(
        id: "toggle",
        initial: "inactive",
        context: EmptyContext(),
        states: [
            "inactive": StateNodeConfig(on: transitions(on(Flip.self, to: S.active))),
            "active": StateNodeConfig(on: transitions(on(Flip.self, to: S.inactive))),
        ]
    )
}

private enum Worker {
    struct Start: StateEvent, Equatable { static let eventType = "START" }
    struct Boom: StateEvent, Equatable { static let eventType = "BOOM" }

    @MachineStates("S")
    static let config = MachineConfig(
        id: "worker",
        initial: "idle",
        context: EmptyContext(),
        states: [
            "idle": StateNodeConfig(on: transitions(on(Start.self, to: S.working))),
            "working": StateNodeConfig(on: transitions(on(Boom.self, to: S.crashed))),
            "crashed": StateNodeConfig(),
        ]
    )
}

// MARK: - Deterministic helpers (no Task.sleep polling)

/// Subscribe to `bus` *before* running `trigger`, then await the first event matching `predicate`.
/// Resolves the instant the event lands; falls back to `nil` on timeout so a hang fails the
/// assertion rather than the suite.
@discardableResult
private func awaitScoped(
    on bus: EventBus,
    timeout: Duration = .seconds(5),
    where predicate: @escaping @Sendable (ScopedInspectionEvent) -> Bool,
    after trigger: () async -> Void
) async -> ScopedInspectionEvent? {
    let oneShot = OneShot<ScopedInspectionEvent?>()
    let token = bus.addSink { event in
        if predicate(event) { oneShot.resolve(event) }
    }
    defer { bus.removeSink(token) }

    let timeoutTask = Task {
        try? await Task.sleep(for: timeout)
        oneShot.resolve(nil)
    }
    defer { timeoutTask.cancel() }

    await trigger()
    return await oneShot.get()
}

private func snapshotValue(_ event: ScopedInspectionEvent) -> String? {
    if case let .inspection(inner) = event.payload, inner.kind == .snapshot {
        return inner.snapshot?.value
    }
    return nil
}

@Suite("Interactor: the inter-actor plane")
struct InteractorTests {

    @Test("typed cross-Interactor send drives the hosted actor (run-to-completion preserved)")
    func typedSend() async {
        let ui = Interactor(id: "ui")
        let toggle = await ui.spawn(createMachine(Toggle.config))

        let landed = await awaitScoped(on: ui.bus, where: { snapshotValue($0) == "active" }) {
            await toggle.send(Toggle.Flip())   // a typed value — no string keys
        }

        #expect(landed != nil)
        let snapshot = await toggle.snapshot()
        #expect(snapshot?.matches("active") == true)
    }

    @Test("FIFO ordering across two posts: idle → working → crashed in order")
    func fifoOrdering() async {
        let workers = Interactor(id: "workers")
        let worker = await workers.spawn(createMachine(Worker.config))

        let crashed = await awaitScoped(on: workers.bus, where: { snapshotValue($0) == "crashed" }) {
            await worker.send(Worker.Start())   // idle → working
            await worker.send(Worker.Boom())    // working → crashed (only reachable if Start ran first)
        }
        #expect(crashed != nil)
    }

    @Test("three Interactors merge into one namespaced, uniquely-sequenced stream")
    func unifiedStream() async {
        let hub = InspectionHub()
        let ui = Interactor(id: "ui")
        let workers = Interactor(id: "workers")
        let sensors = Interactor(id: "sensors")
        hub.attach(ui).attach(workers).attach(sensors)

        // Track everything the hub emits; resolve once all three domains report "active".
        final class Tracker: @unchecked Sendable {
            let lock = NSLock()
            var events: [ScopedInspectionEvent] = []
            var active: Set<String> = []
            let done = OneShot<Void>()
            func add(_ event: ScopedInspectionEvent) {
                lock.lock()
                events.append(event)
                if snapshotValue(event) == "active" { active.insert(event.interactorID) }
                let finished = active.count == 3
                lock.unlock()
                if finished { done.resolve(()) }
            }
            func snapshot() -> [ScopedInspectionEvent] { lock.lock(); defer { lock.unlock() }; return events }
        }
        let tracker = Tracker()
        let token = hub.events.addSink { tracker.add($0) }
        defer { hub.events.removeSink(token) }

        // Same machine id ("toggle") in all three — namespacing must keep them distinct.
        let a = await ui.spawn(createMachine(Toggle.config))
        let b = await workers.spawn(createMachine(Toggle.config))
        let c = await sensors.spawn(createMachine(Toggle.config))
        await a.send(Toggle.Flip())
        await b.send(Toggle.Flip())
        await c.send(Toggle.Flip())

        let timeoutTask = Task { try? await Task.sleep(for: .seconds(5)); tracker.done.resolve(()) }
        defer { timeoutTask.cancel() }
        await tracker.done.get()

        let collected = tracker.snapshot()

        // All three domains represented.
        let interactorIDs = Set(collected.map(\.interactorID))
        #expect(interactorIDs.isSuperset(of: ["ui", "workers", "sensors"]))

        // No id collision: the three "toggle" actors are distinct qualified addresses.
        let activeAddresses = Set(
            collected.compactMap { event -> String? in
                guard case let .inspection(inner) = event.payload, inner.kind == .snapshot,
                      inner.snapshot?.value == "active" else { return nil }
                return "\(event.interactorID)/\(inner.actor.sessionId)"
            }
        )
        #expect(activeAddresses == ["ui/toggle", "workers/toggle", "sensors/toggle"])

        // The single merge point assigns a clean total order: every event has a unique globalSeq.
        let seqs = collected.compactMap(\.globalSeq)
        #expect(seqs.count == collected.count)
        #expect(Set(seqs).count == seqs.count)
    }

    @Test("supervision restarts a hosted actor when it enters its failure state")
    func supervisionRestart() async {
        let workers = Interactor(id: "workers")
        let worker = await workers.spawn(
            createMachine(Worker.config),
            supervision: .restartOnState("crashed")
        )

        await worker.send(Worker.Start())   // idle → working

        let restarted = await awaitScoped(on: workers.bus, where: { event in
            if case let .lifecycle(life) = event.payload { return life.kind == .restarted }
            return false
        }) {
            await worker.send(Worker.Boom())  // working → crashed → supervisor restarts
        }

        #expect(restarted != nil)
        // Back to the initial state on the fresh instance.
        let back = await worker.snapshot()
        #expect(back?.matches("idle") == true)
    }

    @Test("UnifiedGraph folds the merged stream into clusters + cross-domain edges")
    func unifiedGraphProjection() async {
        var graph = UnifiedGraph()
        graph.apply(ScopedInspectionEvent(
            interactorID: "ui", lamport: 1, globalSeq: 1, timestamp: 0,
            payload: .lifecycle(.init(kind: .spawned,
                actor: ActorAddress(interactorID: "ui", actorID: "nav"), detail: "navigator"))
        ))
        graph.apply(ScopedInspectionEvent(
            interactorID: "workers", lamport: 1, globalSeq: 2, timestamp: 0,
            payload: .lifecycle(.init(kind: .spawned,
                actor: ActorAddress(interactorID: "workers", actorID: "job"), detail: "job"))
        ))
        graph.apply(ScopedInspectionEvent(
            interactorID: "workers", lamport: 2, globalSeq: 3, timestamp: 0,
            payload: .message(.init(
                from: ActorAddress(interactorID: "ui", actorID: "nav"),
                to: ActorAddress(interactorID: "workers", actorID: "job"),
                event: "START", correlation: UUID()))
        ))

        #expect(graph.clusters.keys.sorted() == ["ui", "workers"])
        #expect(graph.edges.count == 1)
        #expect(graph.edges.first?.event == "START")
        #expect(graph.edges.first?.from.interactorID == "ui")
        #expect(graph.edges.first?.to.interactorID == "workers")
    }
}
