import ChessKit
import Foundation
import SwiftXState

/// Read-only supervisor over the pure opening move-tree actor.
public actor OpeningWatcher {
    public let dataset: OpeningDataset
    private var recognition: OpeningRecognitionState
    private var reports: [PlyReport] = []
    private var dag: TranspositionDAG
    private let treeSessionId: String?

    public init(dataset: OpeningDataset = .bundled, treeSessionId: String? = nil) throws {
        self.dataset = dataset
        self.treeSessionId = treeSessionId
        self.dag = TranspositionDAG(knownFENs: Set(dataset.equivalence.keys))
        self.recognition = try OpeningRecognitionState()
    }

    public func recordedReports() -> [PlyReport] {
        reports
    }

    public func transpositionDAG() -> TranspositionDAG {
        dag
    }

    public func handleInspection(_ event: InspectionEvent) async {
        guard event.actor.machineId == OpeningMoveTreeMachine.id else { return }
        if let treeSessionId, event.actor.sessionId != treeSessionId {
            return
        }
        guard let snapshot = event.snapshot,
              let description = event.event,
              description.type.hasPrefix("SAN."),
              event.kind == .transition else {
            return
        }
        let san = String(description.type.dropFirst(4))
        let ply = ply(from: snapshot)
        do {
            try recognition.apply(moveSAN: san)
            let report = try await buildReport(ply: max(ply, reports.count + 1), moveSAN: san)
            reports.append(report)
        } catch {
            return
        }
    }

    public func process(step: OpeningTraceStep) async throws {
        try recognition.apply(moveSAN: step.moveSAN)
        let report = try await buildReport(ply: step.ply, moveSAN: step.moveSAN)
        reports.append(report)
    }

    public func process(trace: [OpeningTraceStep]) async throws {
        try await reset()
        for step in trace {
            try await process(step: step)
        }
    }

    public func reset() async throws {
        reports.removeAll(keepingCapacity: true)
        recognition = try OpeningRecognitionState()
        dag = TranspositionDAG(knownFENs: Set(dataset.equivalence.keys))
    }

    private func buildReport(ply: Int, moveSAN: String) async throws -> PlyReport {
        let primary = recognition.primaryOpening(in: dataset)
        let also = recognition.alsoTransposed(into: dataset, primary: primary)
        let probe = await OpeningTranspositionProbe.probeOneMoveAway(
            input: OpeningTranspositionProbe.ProbeInput(
                board: recognition.board,
                dataset: dataset,
                dag: dag
            )
        )
        dag = probe.dag
        return PlyReport(
            ply: ply,
            move: moveSAN,
            currentPosition: recognition.fen,
            primaryOpening: primary,
            alsoTransposedInto: also,
            oneMoveAway: probe.candidates
        )
    }

    private func ply(from snapshot: InspectionSnapshot) -> Int {
        guard case let .object(context) = snapshot.context,
              case let .number(value) = context["ply"] else {
            return 0
        }
        return Int(value)
    }
}

/// Serializes inspect callbacks so watcher transitions stay ordered.
private actor OpeningInspectSink {
    private let watcher: OpeningWatcher

    init(watcher: OpeningWatcher) {
        self.watcher = watcher
    }

    func ingest(_ event: InspectionEvent) async {
        await watcher.handleInspection(event)
    }
}

/// Wires the base tree actor and watcher. The watcher never sends to the tree actor.
public final class OpeningTreeSession: @unchecked Sendable {
    public let dataset: OpeningDataset
    public let actor: Actor<OpeningTreeContext>
    public let trace: OpeningTransitionTrace
    private let watcher: OpeningWatcher
    private let inspectSink: OpeningInspectSink
    private let inspectMux = InspectMux()

    public init(dataset: OpeningDataset = .bundled) throws {
        self.dataset = dataset
        self.trace = OpeningTransitionTrace(machineId: OpeningMoveTreeMachine.id, rootId: dataset.rootId)
        let machine = OpeningMoveTreeMachine.make(dataset: dataset)
        self.actor = createActor(
            machine,
            options: ActorOptions(inspect: inspectMux.observe())
        )
        self.watcher = try OpeningWatcher(dataset: dataset, treeSessionId: actor.id)
        self.inspectSink = OpeningInspectSink(watcher: watcher)
        inspectMux.add(trace.observe())
        inspectMux.add { [inspectSink] event in
            Task { await inspectSink.ingest(event) }
        }
        actor.start()
    }

    public func attachInspect(_ handler: @escaping @Sendable (InspectionEvent) -> Void) {
        inspectMux.add(handler)
        // Actor registration fires in init/start before external inspect hooks attach.
        // Replay so Stately receives @xstate.actor before transition/snapshot events.
        replayActorRegistration(to: handler)
    }

    private func replayActorRegistration(to handler: @Sendable (InspectionEvent) -> Void) {
        let actorRef = InspectionActorRef(
            sessionId: actor.id,
            systemId: actor.systemId,
            machineId: OpeningMoveTreeMachine.id
        )
        handler(
            InspectionEvent.actor(
                rootId: actor.id,
                actor: actorRef,
                registrationSnapshot: InspectionSnapshot.from(actor.snapshot, actor: actorRef)
            )
        )
    }

    public func send(san: String) {
        actor.send(OpeningMoveEvent(san: san))
    }

    public func sendAndWait(san: String) async {
        let expected = await watcher.recordedReports().count + 1
        actor.send(OpeningMoveEvent(san: san))
        for _ in 0..<2000 {
            if await watcher.recordedReports().count >= expected { return }
            try? await Task.sleep(nanoseconds: 500_000)
        }
    }

    public func snapshot() -> MachineSnapshot<OpeningTreeContext> {
        actor.snapshot
    }

    public func availableMoves() -> [String] {
        OpeningMoveTreeMachine.availableMoves(from: actor.snapshot.context.nodeId, dataset: dataset)
    }

    public func reports() async -> [PlyReport] {
        await watcher.recordedReports()
    }

    public func processTrace() async throws -> [PlyReport] {
        try await watcher.process(trace: trace.recordedSteps())
        return await watcher.recordedReports()
    }

    public func transpositionDAG() async -> TranspositionDAG {
        await watcher.transpositionDAG()
    }

    public func reset() async throws {
        trace.reset()
        actor.start(context: .initial(rootId: dataset.rootId))
        try await watcher.reset()
    }
}

private final class InspectMux: @unchecked Sendable {
    private var handlers: [@Sendable (InspectionEvent) -> Void] = []
    private let lock = NSLock()

    func add(_ handler: @escaping @Sendable (InspectionEvent) -> Void) {
        lock.lock()
        handlers.append(handler)
        lock.unlock()
    }

    func observe() -> @Sendable (InspectionEvent) -> Void {
        { [self] event in
            lock.lock()
            let current = handlers
            lock.unlock()
            for handler in current {
                handler(event)
            }
        }
    }
}