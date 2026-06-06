#if os(iOS)
import SwiftUI
import SwiftXStateGraph
import SwiftXStateInspectorUI

// iPad / iPhone UI for SwiftXChess. Two switchable pathways (try both live via the toolbar menu):
//
//   A · Tabs  — board is the hero on a "Game" tab; the live inspector is its own tab. Best for
//               focus and touch; works great in portrait and landscape.
//   B · Split — sidebar (status / controls / tall openings) beside the board stacked over the live
//               state graph. "Inspect" morphs the whole pane into the full MachineInspectorView
//               (info bar + sidebar + actors drawer + graph); "Game" morphs back. Portrait-locked.
//
// macOS is unaffected — `ContentView` only routes here under `#if os(iOS)`.

enum IPadChessLayout: String, CaseIterable, Identifiable {
    case tabs = "Tabs"
    case split = "Split view"
    var id: String { rawValue }
    var label: String { self == .tabs ? "A · Tabs" : "B · Split view" }
    var symbol: String { self == .tabs ? "rectangle.split.1x2" : "sidebar.left" }
}

struct IPadChessRoot: View {
    let session: DistributedChessSession?
    let store: InspectorStore?
    @AppStorage("chessIPadLayout") private var layoutRaw = IPadChessLayout.tabs.rawValue

    private var layout: IPadChessLayout { IPadChessLayout(rawValue: layoutRaw) ?? .tabs }

    var body: some View {
        if let session {
            switch layout {
            case .tabs:
                IPadTabsLayout(session: session, store: store, layoutRaw: $layoutRaw)
            case .split:
                IPadSplitLayout(session: session, store: store, layoutRaw: $layoutRaw)
            }
        } else {
            ContentUnavailableView(
                "Chess unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Could not start the distributed chess session.")
            )
        }
    }
}

// MARK: - A · Tabs

private struct IPadTabsLayout: View {
    @Bindable var session: DistributedChessSession
    let store: InspectorStore?
    @Binding var layoutRaw: String
    @State private var scrubberStep: Double = 0

    var body: some View {
        TabView {
            NavigationStack {
                IPadGameScreen(session: session, scrubberStep: $scrubberStep)
                    .navigationTitle("Distributed Chess")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { LayoutMenu(layoutRaw: $layoutRaw) } }
            }
            .tabItem { Label("Game", systemImage: "checkerboard.rectangle") }

            NavigationStack {
                InspectorPane(store: store)
                    .navigationTitle("Inspector")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Inspector", systemImage: "point.3.connected.trianglepath.dotted") }
        }
    }
}

/// Board hero + a controls column, reflowing between landscape (side-by-side) and portrait (stacked).
private struct IPadGameScreen: View {
    @Bindable var session: DistributedChessSession
    @Binding var scrubberStep: Double

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= geo.size.height
            if wide {
                let controlsWidth = min(360, geo.size.width * 0.38)
                HStack(spacing: 0) {
                    boardPane(area: CGSize(width: geo.size.width - controlsWidth, height: geo.size.height))
                    Divider()
                    controlsPane.frame(width: controlsWidth)
                }
            } else {
                VStack(spacing: 0) {
                    boardPane(area: CGSize(width: geo.size.width, height: geo.size.height * 0.58))
                    Divider()
                    controlsPane
                }
            }
        }
    }

    private func boardPane(area: CGSize) -> some View {
        ChessBoardView(
            board: session.context.board,
            selected: session.context.selected,
            pendingPromotion: session.context.pendingPromotion,
            promotionColor: session.context.turn,
            isInteractive: !session.context.isReplayMode && session.context.outcome == nil,
            onTap: { row, col in Task { await session.tap(row: row, col: col) } },
            onPromote: { kind in Task { await session.promote(to: kind) } },
            tileSize: boardTileSize(for: area)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlsPane: some View {
        ScrollView {
            IPadInfoStack(session: session, scrubberStep: $scrubberStep)
                .padding()
        }
    }
}

// MARK: - B · Split view

private struct IPadSplitLayout: View {
    @Bindable var session: DistributedChessSession
    let store: InspectorStore?
    @Binding var layoutRaw: String
    @State private var scrubberStep: Double = 0
    @State private var inspectorMode = false
    @State private var inspectorTab: InspectorTab = .state
    @State private var actorsExpanded = true

    private var inspectorGraphStyle: GraphStyle {
        var style = GraphStyle.dark
        style.nodeLayoutOverride = BoardInspectorMachine.gridLayoutOverride()
        return style
    }

    // The whole screen is assembled from composable pieces. Entering inspector mode animates each
    // inspector piece in from its own edge — info bar from the top, panel over the sidebar, actors
    // drawer up from the bottom — while the main canvas cross-fades from board to inspector graph.
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if inspectorMode, let store {
                InspectorInfoBar(store: store)
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }

            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    gameSidebar
                    if inspectorMode, let store {
                        InspectorPanel(store: store, tab: $inspectorTab)
                            .frame(width: 320)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .frame(width: 320)

                Divider()
                mainCanvas
            }
            .frame(maxHeight: .infinity)

            if inspectorMode, let store {
                InspectorActorsDrawer(store: store, expanded: $actorsExpanded)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(.systemBackground))
        .inspectorStyle(.dark)
        .animation(.easeInOut(duration: 0.4), value: inspectorMode)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            LayoutMenu(layoutRaw: $layoutRaw)
            Spacer()
            Text(inspectorMode ? "Inspector" : "Distributed Chess")
                .font(.headline)
            Spacer()
            Button {
                if !inspectorMode { selectGameWatcher() }
                inspectorMode.toggle()
            } label: {
                Label(
                    inspectorMode ? "Game" : "Inspect",
                    systemImage: inspectorMode ? "checkerboard.rectangle" : "point.3.connected.trianglepath.dotted"
                )
            }
            .disabled(store == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The board over the live game-watcher graph — stays put across modes. Entering the inspector
    /// brings the chrome (info bar / panel / actors drawer) in around it; it doesn't swap in a new graph.
    private var mainCanvas: some View {
        boardAndGraph
    }

    private var gameSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            IPadStatusCard(session: session)
            IPadControlsCard(session: session, scrubberStep: $scrubberStep)
            OpeningPanelView(
                availableMoves: session.availableOpeningMoves,
                latestReport: session.latestReport,
                openingActive: session.openingActive,
                atPlyLimit: session.atPlyLimit,
                moveHistory: session.reports.map(\.move),
                fillsAvailableHeight: true,
                startsExpanded: true
            )
            .frame(maxHeight: .infinity)
        }
        .padding()
        .frame(width: 320)
    }

    private var boardAndGraph: some View {
        GeometryReader { geo in
            // Fill the column width (capped by height so the graph keeps ~40%). The board sits
            // flush at the top — no surrounding letterbox padding — and the graph fills the rest.
            let tile = max(34, min((geo.size.width - 38) / 8, (geo.size.height * 0.60 - 34) / 8))
            VStack(spacing: 0) {
                ChessBoardView(
                    board: session.context.board,
                    selected: session.context.selected,
                    pendingPromotion: session.context.pendingPromotion,
                    promotionColor: session.context.turn,
                    isInteractive: !session.context.isReplayMode && session.context.outcome == nil,
                    onTap: { row, col in Task { await session.tap(row: row, col: col) } },
                    onPromote: { kind in Task { await session.promote(to: kind) } },
                    tileSize: tile
                )
                .frame(maxWidth: .infinity)

                Divider()

                graphPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
    }

    /// Game mode: the live game-watcher graph. Inspector mode: the *selected* actor's graph, so the
    /// bottom actors drawer drives what's shown.
    @ViewBuilder
    private var graphPane: some View {
        if inspectorMode, let store {
            InspectorGraphView(store: store, graphStyle: inspectorGraphStyle)
        } else {
            MachineGraphView(actor: session.actor, machine: session.machine)
                .graphStyle(.dark)
        }
    }

    /// Open the inspector on the game-watcher (rather than whichever board actor registered first).
    private func selectGameWatcher() {
        guard let store else { return }
        if let watcher = store.actors.first(where: { $0.machineID == GameWatcherMachine.id }) {
            store.selectedSessionID = watcher.sessionID
        }
    }
}

// MARK: - Shared pieces

/// The compact info/controls column reused by both layouts.
private struct IPadInfoStack: View {
    @Bindable var session: DistributedChessSession
    @Binding var scrubberStep: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IPadStatusCard(session: session)
            IPadControlsCard(session: session, scrubberStep: $scrubberStep)
            OpeningPanelView(
                availableMoves: session.availableOpeningMoves,
                latestReport: session.latestReport,
                openingActive: session.openingActive,
                atPlyLimit: session.atPlyLimit,
                moveHistory: session.reports.map(\.move)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IPadStatusCard: View {
    let session: DistributedChessSession

    var body: some View {
        GroupBox("Game") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Turn", value: session.statusLine)
                LabeledContent("Ply", value: "\(session.context.plyCount)")
                LabeledContent("Actors", value: "\(session.snapshot.children.count)")
                LabeledContent("State") {
                    Text(session.snapshot.value.description)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct IPadControlsCard: View {
    @Bindable var session: DistributedChessSession
    @Binding var scrubberStep: Double

    var body: some View {
        GroupBox("Controls") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { try? await session.newGame() }
                } label: {
                    Label("New game", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                replaySection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var replaySection: some View {
        Divider()
        if session.canReplay {
            if session.context.isReplayMode {
                Slider(value: $scrubberStep, in: 0...Double(max(session.replayStepCount, 1)), step: 1)
                    .onChange(of: scrubberStep) { _, step in session.scrubReplay(to: Int(step)) }
                Text("Step \(session.context.replayStep) of \(session.replayStepCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Exit replay") { session.exitReplay() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Enter replay") {
                    session.enterReplay()
                    scrubberStep = Double(session.context.replayStep)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Text("Make a move to enable replay.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The live inspector, or a placeholder if no store/session.
private struct InspectorPane: View {
    let store: InspectorStore?

    private var graphStyle: GraphStyle {
        var style = GraphStyle.dark
        style.nodeLayoutOverride = BoardInspectorMachine.gridLayoutOverride()
        return style
    }

    var body: some View {
        if let store {
            MachineInspectorView(store: store, graphStyle: graphStyle)
                .inspectorStyle(.dark)
                .ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableView(
                "Inspector unavailable",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("The chess session could not be started.")
            )
        }
    }
}

/// Toolbar menu to flip between layout A and B (persisted via @AppStorage).
private struct LayoutMenu: View {
    @Binding var layoutRaw: String

    var body: some View {
        Menu {
            Picker("Layout", selection: $layoutRaw) {
                ForEach(IPadChessLayout.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option.rawValue)
                }
            }
        } label: {
            Label("Layout", systemImage: "rectangle.3.group")
        }
    }
}

// MARK: - Board sizing

/// Largest square edge that fits the board (8 tiles + rank/file labels + padding ≈ `8·tile + 38`)
/// into the smaller dimension of `area`, clamped to a touch-friendly range.
private func boardTileSize(for area: CGSize, maxTile: CGFloat = 62) -> CGFloat {
    let edge = min(area.width, area.height) - 24
    let tile = (edge - 38) / 8
    return max(34, min(maxTile, tile))
}
#endif
