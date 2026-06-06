import Foundation
import SwiftUI
import SwiftXChessOpenings
import SwiftXState
import SwiftXStateInspect
import SwiftXStateInspectURLSession

@MainActor
@Observable
final class OpeningDemoSession {
    private let treeSession: OpeningTreeSession
    private var bridge: InspectBridge?

    private(set) var snapshot: MachineSnapshot<OpeningTreeContext>
    private(set) var reports: [PlyReport] = []
    private(set) var connectionStatus = "Idle"
    private(set) var inspectorEndpoint: String

    var context: OpeningTreeContext { snapshot.context }
    var moveHistory: [String] { reports.map(\.move) }
    var latestReport: PlyReport? { reports.last }
    var availableMoves: [String] { treeSession.availableMoves() }
    var atPlyLimit: Bool { context.ply >= 10 }

    init(
        host: String = "127.0.0.1",
        port: Int = 8080
    ) throws {
        let endpoint = InspectEndpoint(host: host, port: port)
        inspectorEndpoint = endpoint.url?.absoluteString ?? "ws://\(host):\(port)"
        let transport = URLSessionInspect.transport(
            policy: .localhostOnly(ports: .only([port])),
            runtime: InspectRuntimeContext(isDebugBuild: true)
        )

        let treeSession = try OpeningTreeSession()
        self.treeSession = treeSession
        snapshot = treeSession.snapshot()

        do {
            let machine = OpeningMoveTreeMachine.make()
            let configuration = InspectClientConfiguration(
                policy: .localhostOnly(ports: .only([endpoint.port])),
                endpoint: endpoint,
                runtime: InspectRuntimeContext(isDebugBuild: true),
                enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
                wireFormat: .stately,
                machineDefinitions: [try InspectMachineRegistration(machine)]
            )
            let bridge = InspectBridge(transport: transport, configuration: configuration)
            bridge.start()
            treeSession.attachInspect(bridge.observe())
            self.bridge = bridge
            connectionStatus = "Connected → Stately Inspector"
        } catch {
            connectionStatus = "Inspect unavailable"
            inspectorEndpoint = String(describing: error)
        }
    }

    func send(san: String) async {
        guard !atPlyLimit else { return }
        await treeSession.sendAndWait(san: san)
        snapshot = treeSession.snapshot()
        reports = await treeSession.reports()
    }

    func playLine(_ moves: [String]) async throws {
        try await reset()
        for move in moves.prefix(10) {
            await send(san: move)
        }
    }

    func reset() async throws {
        try await treeSession.reset()
        snapshot = treeSession.snapshot()
        reports = []
    }

    func stopInspect() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
        connectionStatus = "Disconnected"
    }
}