import Foundation
import SwiftUI
import SwiftXChessOpenings
import SwiftXState
import SwiftXStateInspect
import SwiftXStateInspectURLSession

@MainActor
@Observable
final class DistributedChessSession {
    /// The typed Plan D actor — `send` takes a `ChessEvent`, no `any Eventable` at the call site.
    let machineActor: MachineActor<GameWatcherMachine>
    /// The underlying engine actor — for the inspector bridge + graph view.
    var actor: Actor<MachineLogic<GameWatcherContext>> { machineActor.actor }
    /// The machine the actor runs — exposed so a graph view can visualize this exact session.
    let machine: ResolvedMachine<GameWatcherContext>
    private let treeSession: OpeningTreeSession
    private var bridge: InspectBridge?
    let recorder = InspectionRecorder()
    private let recordingGate = ReplayRecordingGate()

    private(set) var snapshot: MachineSnapshot<GameWatcherContext>
    private(set) var treeSnapshot: MachineSnapshot<OpeningTreeContext>
    private(set) var reports: [PlyReport] = []
    private(set) var connectionStatus = "Idle"
    private(set) var inspectorEndpoint: String
    private(set) var openingActive = true
    private var lastSyncedPly = 0
    /// Observable mirror of `recorder.recordedSteps().count` (Observation does not track the recorder).
    private(set) var recordedStepCount = 0

    var context: GameWatcherContext { snapshot.context }

    var canReplay: Bool { recordedStepCount > 1 }

    var replayStepCount: Int {
        guard let session = context.replaySession else { return 0 }
        return max(session.steps.count - 1, 0)
    }

    /// Opening-tree edges from the current node. Mirrored into an observable property and refreshed
    /// after each move, since Observation can't track the async opening-tree actor directly.
    private(set) var availableOpeningMoves: [String] = []

    private func refreshOpeningMoves() async {
        guard openingActive, !atPlyLimit else {
            availableOpeningMoves = []
            return
        }
        availableOpeningMoves = await treeSession.availableMoves()
    }

    var latestReport: PlyReport? { reports.last }
    var atPlyLimit: Bool { context.plyCount >= 10 }

    var statusLine: String {
        if context.isReplayMode {
            let total = max((context.replaySession?.steps.count ?? 1) - 1, 0)
            return "Replay step \(context.replayStep)/\(total)"
        }
        if let outcome = context.outcome {
            switch outcome {
            case .checkmateWhite: return "Checkmate — White wins"
            case .checkmateBlack: return "Checkmate — Black wins"
            case .stalemate: return "Stalemate — Draw"
            }
        }
        if context.pendingPromotion != nil {
            return "\(context.turn.rawValue.capitalized) — choose promotion"
        }
        if !openingActive {
            return "\(context.turn.rawValue.capitalized) to move · opening watcher dormant"
        }
        return "\(context.turn.rawValue.capitalized) to move"
    }

    init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        extraInspect: (@Sendable (InspectionEvent) -> Void)? = nil
    ) async throws {
        let endpoint = InspectEndpoint(host: host, port: port)
        inspectorEndpoint = endpoint.url?.absoluteString ?? "ws://\(host):\(port)"
        let transport = URLSessionInspect.transport(
            policy: .localhostOnly(ports: .only([port])),
            runtime: InspectRuntimeContext(isDebugBuild: true)
        )

        self.treeSession = try await OpeningTreeSession()
        treeSnapshot = await treeSession.snapshot()

        // Stream the 96 per-square/piece board actors too — a deliberate stress test for the
        // inspector (this actor count kills the web client; the native one handles it).
        let gameMachine = GameWatcherMachine.make(inspectableBoardActors: false)
        self.machine = gameMachine
        let watcher = GameWatcherMachine(includeBoardSpawns: true, inspectableBoardActors: false)

        do {
            let configuration = InspectClientConfiguration(
                policy: .localhostOnly(ports: .only([endpoint.port])),
                endpoint: endpoint,
                runtime: InspectRuntimeContext(isDebugBuild: true),
                enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
                wireFormat: .stately,
                machineDefinitions: [
                    try InspectMachineRegistration(
                        machineId: GameWatcherMachine.id,
                        definitionJSON: GameWatcherMachine.inspectorSummaryMachine().definitionJSON()
                    ),
                    try InspectMachineRegistration(
                        machineId: OpeningMoveTreeMachine.id,
                        definitionJSON: OpeningMoveTreeMachine.inspectorSummaryMachine().definitionJSON(),
                        wireStateValue: .inspectorWireState
                    ),
                    try InspectMachineRegistration(
                        machineId: BoardInspectorMachine.id(.occupancy),
                        definitionJSON: BoardInspectorMachine.make(mode: .occupancy).definitionJSON()
                    ),
                    try InspectMachineRegistration(
                        machineId: BoardInspectorMachine.id(.pieces),
                        definitionJSON: BoardInspectorMachine.make(mode: .pieces).definitionJSON()
                    ),
                ]
            )
            let bridge = InspectBridge(transport: transport, configuration: configuration)
            await bridge.start()
            let bridgeInspect = bridge.observe()
            let combined = Self.combineInspect(recordingGate.observe(recorder), bridgeInspect)
            let inspect = Self.combineInspect(combined, extraInspect ?? { _ in })
            let machineActor = createActor(watcher, id: GameWatcherMachine.id, inspect: inspect)
            await machineActor.start()
            await treeSession.attachInspect(Self.combineInspect(bridgeInspect, extraInspect ?? { _ in }))
            self.machineActor = machineActor
            self.bridge = bridge
            connectionStatus = "Connected → Stately Inspector"
            snapshot = await machineActor.actor.snapshot
            syncRecordingState()
        } catch {
            let inspect = Self.combineInspect(recordingGate.observe(recorder), extraInspect ?? { _ in })
            let machineActor = createActor(watcher, id: GameWatcherMachine.id, inspect: inspect)
            await machineActor.start()
            self.machineActor = machineActor
            connectionStatus = "Inspect unavailable"
            inspectorEndpoint = String(describing: error)
            snapshot = await machineActor.actor.snapshot
            syncRecordingState()
        }
        await refreshOpeningMoves()
    }

    func tap(row: Int, col: Int) async {
        guard !context.isReplayMode, context.outcome == nil else { return }
        let event = ChessEvent.tap(Square(row: row, col: col))
        await machineActor.send(event)
        snapshot = await actor.snapshot
        syncRecordingState()
        await syncOpeningTree()
    }

    func promote(to kind: PieceKind) async {
        guard !context.isReplayMode, context.pendingPromotion != nil else { return }
        await machineActor.send(.promote(kind))
        snapshot = await actor.snapshot
        syncRecordingState()
        await syncOpeningTree()
    }

    func enterReplay() async {
        guard let session = recorder.session() else { return }
        recordingGate.setEnabled(false)
        ChessReplayBridge.setPendingSession(session)
        await machineActor.send(.enterReplay)
        snapshot = await actor.snapshot
    }

    func exitReplay() async {
        await machineActor.send(.exitReplay)
        snapshot = await actor.snapshot
        recordingGate.setEnabled(true)
    }

    func scrubReplay(to step: Int) async {
        guard context.isReplayMode else { return }
        let clamped = min(max(step, 0), replayStepCount)
        guard clamped != context.replayStep else { return }
        await machineActor.send(.replayScrub(clamped))
        snapshot = await actor.snapshot
    }

    func newGame() async throws {
        recordingGate.setEnabled(true)
        await machineActor.send(.newGame)
        snapshot = await actor.snapshot
        syncRecordingState()
        try await treeSession.reset()
        treeSnapshot = await treeSession.snapshot()
        reports = []
        openingActive = true
        lastSyncedPly = 0
        await refreshOpeningMoves()
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
        connectionStatus = "Disconnected"
    }

    private func syncRecordingState() {
        recordedStepCount = recorder.recordedSteps().count
    }

    private static func combineInspect(
        _ recorderInspect: @escaping @Sendable (InspectionEvent) -> Void,
        _ statelyInspect: @escaping @Sendable (InspectionEvent) -> Void
    ) -> @Sendable (InspectionEvent) -> Void {
        { event in
            recorderInspect(event)
            statelyInspect(event)
        }
    }

    private func syncOpeningTree() async {
        guard context.plyCount > lastSyncedPly else { return }
        lastSyncedPly = context.plyCount

        guard openingActive, !atPlyLimit, let san = context.lastSAN, !san.isEmpty else {
            if atPlyLimit { openingActive = false }
            await refreshOpeningMoves()
            return
        }

        let legalInTree = await treeSession.availableMoves()
        guard legalInTree.contains(san) else {
            openingActive = false
            await refreshOpeningMoves()
            return
        }

        await treeSession.sendAndWait(san: san)
        treeSnapshot = await treeSession.snapshot()
        reports = await treeSession.reports()
        await refreshOpeningMoves()
    }
}

extension String {
    /// Atomic state id used in the lightweight inspector graph (runtime uses dataset node ids).
    static var inspectorWireState: String { "tracking" }
}
