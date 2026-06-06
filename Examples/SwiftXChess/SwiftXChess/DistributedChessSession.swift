import Foundation
import SwiftUI
import SwiftXChessOpenings
import SwiftXState
import SwiftXStateInspect
import SwiftXStateInspectURLSession

@MainActor
@Observable
final class DistributedChessSession {
    let actor: Actor<GameWatcherContext>
    /// The machine the actor runs — exposed so a graph view can visualize this exact session.
    let machine: StateMachine<GameWatcherContext>
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

    var availableOpeningMoves: [String] {
        guard openingActive, !atPlyLimit else { return [] }
        return treeSession.availableMoves()
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
    ) throws {
        let endpoint = InspectEndpoint(host: host, port: port)
        inspectorEndpoint = endpoint.url?.absoluteString ?? "ws://\(host):\(port)"
        let transport = URLSessionInspect.transport(
            policy: .localhostOnly(ports: .only([port])),
            runtime: InspectRuntimeContext(isDebugBuild: true)
        )

        let treeSession = try OpeningTreeSession()
        self.treeSession = treeSession
        treeSnapshot = treeSession.snapshot()

        // Stream the 96 per-square/piece board actors too — a deliberate stress test for the
        // inspector (this actor count kills the web client; the native one handles it).
        let gameMachine = GameWatcherMachine.make(inspectableBoardActors: false)
        self.machine = gameMachine

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
                        wireStateValue: OpeningMoveTreeMachine.inspectorWireState
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
            bridge.start()
            let bridgeInspect = bridge.observe()
            let combined = Self.combineInspect(recordingGate.observe(recorder), bridgeInspect)
            let inspect = Self.combineInspect(combined, extraInspect ?? { _ in })
            let actor = createActor(gameMachine, options: ActorOptions(inspect: inspect)).start()
            treeSession.attachInspect(Self.combineInspect(bridgeInspect, extraInspect ?? { _ in }))
            self.actor = actor
            self.bridge = bridge
            connectionStatus = "Connected → Stately Inspector"
            snapshot = actor.snapshot
            syncRecordingState()
        } catch {
            let inspect = Self.combineInspect(recordingGate.observe(recorder), extraInspect ?? { _ in })
            let actor = createActor(
                gameMachine,
                options: ActorOptions(inspect: inspect)
            ).start()
            self.actor = actor
            connectionStatus = "Inspect unavailable"
            inspectorEndpoint = String(describing: error)
            snapshot = actor.snapshot
            syncRecordingState()
        }
    }

    func tap(row: Int, col: Int) async {
        guard !context.isReplayMode, context.outcome == nil else { return }
        let event = ChessEvent.tap(Square(row: row, col: col))
        actor.send(event)
        snapshot = actor.snapshot
        syncRecordingState()
        await syncOpeningTree()
    }

    func promote(to kind: PieceKind) async {
        guard !context.isReplayMode, context.pendingPromotion != nil else { return }
        actor.send(ChessEvent.promote(kind))
        snapshot = actor.snapshot
        syncRecordingState()
        await syncOpeningTree()
    }

    func enterReplay() {
        guard let session = recorder.session() else { return }
        recordingGate.setEnabled(false)
        ChessReplayBridge.setPendingSession(session)
        actor.send(ChessEvent.enterReplay)
        snapshot = actor.snapshot
    }

    func exitReplay() {
        actor.send(ChessEvent.exitReplay)
        snapshot = actor.snapshot
        recordingGate.setEnabled(true)
    }

    func scrubReplay(to step: Int) {
        guard context.isReplayMode else { return }
        let clamped = min(max(step, 0), replayStepCount)
        guard clamped != context.replayStep else { return }
        actor.send(ChessEvent.replayScrub(clamped))
        snapshot = actor.snapshot
    }

    func newGame() async throws {
        recordingGate.setEnabled(true)
        actor.send(ChessEvent.newGame)
        snapshot = actor.snapshot
        syncRecordingState()
        try await treeSession.reset()
        treeSnapshot = treeSession.snapshot()
        reports = []
        openingActive = true
        lastSyncedPly = 0
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
            return
        }

        let legalInTree = treeSession.availableMoves()
        guard legalInTree.contains(san) else {
            openingActive = false
            return
        }

        await treeSession.sendAndWait(san: san)
        treeSnapshot = treeSession.snapshot()
        reports = await treeSession.reports()
    }
}
