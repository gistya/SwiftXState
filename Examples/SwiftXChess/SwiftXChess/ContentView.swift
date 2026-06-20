import SwiftUI
import SwiftXStateSwiftUI
import SwiftXStateGraph
import SwiftXStateInspectorUI

struct ContentView: View {
    /// The shared session, owned by the app so the State Graph window observes the same machine.
    @State var session: DistributedChessSession?
    /// The shared inspector store. Used by the iPad layouts (the inspector is embedded there);
    /// unused on macOS, which has a dedicated Inspector window.
    @State var store: InspectorStore

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
                LazyVStack(alignment: .leading, spacing: 16) {
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
                        Task {
                            await session.enterReplay()
                            scrubberStep = Double(session.context.replayStep)
                        }
                    }
                    if session.context.isReplayMode {
                        Slider(value: $scrubberStep, in: 0...Double(session.replayStepCount), step: 1)
                            .onChange(of: scrubberStep) { _, step in
                                Task { await session.scrubReplay(to: Int(step)) }
                            }
                        Text("Step \(session.context.replayStep) of \(session.replayStepCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Exit replay") { Task { await session.exitReplay() } }
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
