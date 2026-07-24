import Foundation
import SwiftUI
import SwiftXState
import SwiftXStateInspect
import SwiftXStateInspectURLSession
import SwiftXStateSwiftUI

@MainActor
@Observable
final class ChessSession {
    private(set) var snapshot: MachineSnapshot<ChessContext>
    /// The typed Plan D actor. Views read `context`/`snapshot`; `send` goes through the typed facade.
    let machineActor: MachineActor<ChessGameMachine>
    /// The underlying engine actor — for the inspector bridge + graph view.
    var actor: Actor<MachineLogic<ChessContext>> { machineActor.actor }
    /// The resolved machine the actor runs — exposed so a graph view can visualize this session.
    let machine: ResolvedMachine<ChessContext>
    let recorder = InspectionRecorder()

    private(set) var connectionStatus: String = "Idle"
    private(set) var inspectorEndpoint: String

    private let transport: URLSessionInspectTransport
    private let endpoint: InspectEndpoint
    private var bridge: InspectBridge?
    private let recordingGate = ReplayRecordingGate()

    var context: ChessContext { snapshot.context }

    var canReplay: Bool {
        guard let session = recorder.session() else { return false }
        return session.steps.count > 1
    }

    /// Uses the frozen session captured at enter-replay, not the live recorder
    /// (scrub events must not increase the slider maximum).
    var replayStepCount: Int {
        guard let session = context.replaySession else { return 0 }
        return max(session.steps.count - 1, 0)
    }

    init(
        host: String = "127.0.0.1",
        port: Int = 8080
    ) async {
        endpoint = InspectEndpoint(host: host, port: port)
        inspectorEndpoint = endpoint.urlString
        transport = URLSessionInspect.transport(
            policy: .localhostOnly(ports: .only([port])),
            runtime: InspectRuntimeContext(isDebugBuild: true)
        )

        let machine = ChessGameMachine.resolved
        self.machine = machine

        let machineActor: MachineActor<ChessGameMachine>
        do {
            let (bridge, statelyInspect) = try await Self.makeInspectBridge(
                machine: machine,
                transport: transport,
                endpoint: endpoint
            )
            self.bridge = bridge
            let inspect = Self.combineInspect(recordingGate.observe(recorder), statelyInspect)
            machineActor = createActor(ChessGameMachine(), id: ChessGameMachine.id, inspect: inspect)
            connectionStatus = "Connected → Stately Inspector"
        } catch {
            machineActor = createActor(
                ChessGameMachine(),
                id: ChessGameMachine.id,
                inspect: recordingGate.observe(recorder)
            )
            connectionStatus = "Inspect unavailable"
            inspectorEndpoint = String(describing: error)
        }

        self.machineActor = machineActor
        await machineActor.start(context: ChessContext.initial())
        snapshot = await machineActor.actor.snapshot
    }

    func tap(row: Int, col: Int) async {
        await send(.tap(Square(row: row, col: col)))
    }

    func promote(to kind: PieceKind) async {
        await send(.promote(kind))
    }

    func newGame() async {
        recordingGate.setEnabled(true)
        await send(.newGame)
    }

    func enterReplay() async {
        guard let session = recorder.session() else { return }
        recordingGate.setEnabled(false)
        ChessReplayBridge.setPendingSession(session)
        await send(.enterReplay)
    }

    func exitReplay() async {
        await send(.exitReplay)
        recordingGate.setEnabled(true)
    }

    func scrubReplay(to step: Int) async {
        guard context.isReplayMode else { return }
        let clamped = min(max(step, 0), replayStepCount)
        guard clamped != context.replayStep else { return }
        await send(.replayScrub(clamped))
    }

    func send(_ event: ChessEvent) async {
        await machineActor.send(event)
        snapshot = await machineActor.actor.snapshot
    }

    func verifyRecording() -> Bool {
        guard let session = recorder.session() else { return false }
        let results = verifyReplay(machine, context: ChessContext.initial(), session: session)
        return results.allSatisfy(\.matches)
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
        connectionStatus = "Disconnected"
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

    private static func makeInspectBridge(
        machine: ResolvedMachine<ChessContext>,
        transport: URLSessionInspectTransport,
        endpoint: InspectEndpoint
    ) async throws -> (InspectBridge, @Sendable (InspectionEvent) -> Void) {
        let configuration = InspectClientConfiguration(
            policy: .localhostOnly(ports: .only([endpoint.port])),
            endpoint: endpoint,
            runtime: InspectRuntimeContext(isDebugBuild: true),
            enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
            wireFormat: .stately,
            machineDefinitions: [try InspectMachineRegistration(machine)]
        )
        let bridge = InspectBridge(transport: transport, configuration: configuration)
        await bridge.start()
        return (bridge, bridge.observe())
    }
}
