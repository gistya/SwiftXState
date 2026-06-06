import SwiftUI
import SwiftXStateSwiftUI
import SwiftXStateGraph
import SwiftXStateInspectorUI

struct ContentView: View {
    /// The shared session, owned by the app so the State Graph window observes the same machine.
    let session: DistributedChessSession?
    /// The shared inspector store. Used by the iPad layouts (the inspector is embedded there);
    /// unused on macOS, which has a dedicated Inspector window.
    var store: InspectorStore? = nil

    var body: some View {
        #if os(macOS)
        DistributedChessGameView(session: session)
        #else
        IPadChessRoot(session: session, store: store)
        #endif
    }
}

struct DistributedChessGameView: View {
    let session: DistributedChessSession?
    @State private var scrubberStep: Double = 0

    var body: some View {
        Group {
            if let session {
                @Bindable var session = session
                gameContent(session: session)
            } else {
                ContentUnavailableView(
                    "Chess unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not start the distributed chess session.")
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 700)
        #endif
    }

    @ViewBuilder
    private func gameContent(session: DistributedChessSession) -> some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    ChessBoardView(
                        board: session.context.board,
                        selected: session.context.selected,
                        pendingPromotion: session.context.pendingPromotion,
                        promotionColor: session.context.turn,
                        isInteractive: !session.context.isReplayMode && session.context.outcome == nil,
                        onTap: { row, col in
                            Task { await session.tap(row: row, col: col) }
                        },
                        onPromote: { kind in
                            Task { await session.promote(to: kind) }
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                    OpeningPanelView(
                        availableMoves: session.availableOpeningMoves,
                        latestReport: session.latestReport,
                        openingActive: session.openingActive,
                        atPlyLimit: session.atPlyLimit,
                        moveHistory: session.reports.map(\.move)
                    )
                    .layoutPriority(0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    DistributedChessHeader()
                    DistributedMachineCard(session: session)
                    DistributedInspectorCard(session: session)
                    DistributedGameControls(session: session)
                    DistributedReplayControls(session: session, scrubberStep: $scrubberStep)
                }
                .frame(maxWidth: 300, alignment: .leading)
            }
            .padding(24)
            .navigationTitle("Distributed Chess")
        }
    }
}

// MARK: - Sidebar

private struct DistributedChessHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SwiftXState Chess")
                .font(.title2.bold())
            Text("`game-watcher` + `opening-move-tree` + `board-inspector` · 96 board actors off-inspector")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DistributedMachineCard: View {
    let session: DistributedChessSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GroupBox("Machine") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("State") {
                    Text(session.snapshot.value.description)
                        .font(.caption.monospaced())
                }
                LabeledContent("Turn") {
                    Text(session.statusLine)
                        .font(.caption)
                }
                LabeledContent("Board actors") {
                    Text("\(session.snapshot.children.count) (runtime only)")
                        .font(.caption)
                }
                LabeledContent("Ply") {
                    Text("\(session.context.plyCount)")
                }
                LabeledContent("Tree node") {
                    Text(session.treeSnapshot.context.nodeId)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                Button {
                    openWindow(id: "state-graph")
                } label: {
                    Label("Open Inspector", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
                .padding(.top, 2)
                .keyboardShortcut("i", modifiers: [.command])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DistributedInspectorCard: View {
    let session: DistributedChessSession

    var body: some View {
        GroupBox("Stately Inspector") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Status") {
                    Text(session.connectionStatus)
                }
                LabeledContent("Machines") {
                    Text("game-watcher, opening-move-tree")
                        .font(.caption.monospaced())
                }
                LabeledContent("WebSocket") {
                    Text(session.inspectorEndpoint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DistributedGameControls: View {
    let session: DistributedChessSession

    var body: some View {
        GroupBox("Controls") {
            Button("New game") {
                Task { try? await session.newGame() }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DistributedReplayControls: View {
    @Bindable var session: DistributedChessSession
    @Binding var scrubberStep: Double

    var body: some View {
        GroupBox("Replay") {
            VStack(alignment: .leading, spacing: 8) {
                if session.canReplay {
                    Button("Enter replay") {
                        session.enterReplay()
                        scrubberStep = Double(session.context.replayStep)
                    }
                    if session.context.isReplayMode {
                        Slider(value: $scrubberStep, in: 0...Double(session.replayStepCount), step: 1)
                            .onChange(of: scrubberStep) { _, step in
                                session.scrubReplay(to: Int(step))
                            }
                        Text("Step \(session.context.replayStep) of \(session.replayStepCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Exit replay") { session.exitReplay() }
                    }
                } else {
                    Text(replayHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var replayHint: String {
        switch session.recordedStepCount {
        case 0:
            return "Recording not active — rebuild and make a move."
        case 1:
            return "Make a move to enable replay (1 step recorded)."
        default:
            return "Record taps to enable replay."
        }
    }
}

// MARK: - Legacy monolithic game (kept for replay demo)

struct ChessGameView: View {
    @State private var session = ChessSession()
    @State private var scrubberStep: Double = 0
    @State private var showGraphSheet = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var session = session

        NavigationStack {
            HStack(alignment: .top, spacing: 24) {
                ChessBoardView(
                    board: session.context.board,
                    selected: session.context.selected,
                    pendingPromotion: session.context.pendingPromotion,
                    promotionColor: session.context.turn,
                    isInteractive: session.viewState?.isBoardInteractive ?? false,
                    onTap: { row, col in
                        session.tap(row: row, col: col)
                    },
                    onPromote: { kind in
                        session.promote(to: kind)
                    }
                )

                VStack(alignment: .leading, spacing: 16) {
                    ChessGameHeader()
                    MachineStateCard(session: session)

                    // SwiftXStateGraph integration (new library)
                    GroupBox("Graph Visualizer") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live rendering of the current state machine using SwiftXStateGraph (Metal/3D ready, GraphStyle theming, zoom/pan/rearrange).")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("Open in Sheet (this session)") {
                                    showGraphSheet = true
                                }

                                Button("Open Separate Window") {
                                    openWindow(id: "state-graph")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    ChessMoveListCard(session: session)
                    ChessGameControls(session: session, scrubberStep: $scrubberStep)
                    ChessReplayControls(session: session, scrubberStep: $scrubberStep)
                    ChessInspectorCard(session: session)
                }
                .frame(maxWidth: 280, alignment: .leading)
            }
            .padding(24)
            .navigationTitle("Chess + Replay")
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $showGraphSheet) {
            VStack {
                HStack {
                    Text("Live Graph — Current Chess Session")
                        .font(.headline)
                    Spacer()
                    Button("Close") { showGraphSheet = false }
                }
                .padding()

                MachineGraphView(
                    actor: session.actor,
                    machine: ChessMachineFactory.machine
                )
                .graphStyle(.chessDefault)
            }
            .frame(minWidth: 900, minHeight: 650)
        }
    }
}

// MARK: - Chess sidebar cards

private struct ChessGameHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SwiftXState Chess")
                .font(.title2.bold())
            Text("Logic core: `chess` state machine")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MachineStateCard: View {
    let session: ChessSession

    var body: some View {
        let viewState = useMapState(session.actor, ChessViewStateMapper.mapper)

        GroupBox("Machine") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Phase") {
                    Text(viewState?.phase.displayName ?? "—")
                }
                LabeledContent("Turn") {
                    Text(viewState?.statusLine ?? session.context.statusLine)
                }
                LabeledContent("State") {
                    Text(session.snapshot.value.description)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChessMoveListCard: View {
    let session: ChessSession

    var body: some View {
        GroupBox("Moves") {
            ScrollView {
                if session.context.moveHistory.isEmpty {
                    Text("No moves yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(session.context.moveHistory.enumerated()), id: \.offset) { index, move in
                            Text("\(index + 1). \(moveDescription(move))")
                                .font(.caption.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 100)
        }
    }

    private func moveDescription(_ move: ChessMove) -> String {
        let from = BoardActorIds.coord(move.from)
        let to = BoardActorIds.coord(move.to)
        return "\(from)→\(to)"
    }
}

private struct ChessGameControls: View {
    let session: ChessSession
    @Binding var scrubberStep: Double

    var body: some View {
        GroupBox("Game") {
            VStack(alignment: .leading, spacing: 8) {
                Button("New game") { session.newGame() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChessReplayControls: View {
    let session: ChessSession
    @Binding var scrubberStep: Double

    var body: some View {
        GroupBox("Replay") {
            VStack(alignment: .leading, spacing: 8) {
                if session.canReplay {
                    Button("Enter replay") {
                        session.enterReplay()
                        scrubberStep = Double(session.context.replayStep)
                    }
                    if session.viewState?.isReplaying == true {
                        Slider(value: $scrubberStep, in: 0...Double(session.replayStepCount), step: 1)
                            .onChange(of: scrubberStep) { _, step in
                                session.scrubReplay(to: Int(step))
                            }
                        Button("Exit replay") { session.exitReplay() }
                    }
                } else {
                    Text("Record taps to enable replay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChessInspectorCard: View {
    let session: ChessSession

    var body: some View {
        GroupBox("Stately Inspector") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Status") {
                    Text(session.connectionStatus)
                }
                LabeledContent("WebSocket") {
                    Text(session.inspectorEndpoint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
