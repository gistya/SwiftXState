import SwiftUI
import SwiftXChessOpenings

struct OpeningDemoView: View {
    @State private var session: OpeningDemoSession? = try? OpeningDemoSession()

    var body: some View {
        Group {
            if let session {
                @Bindable var session = session
                content(session: session)
            } else {
                ContentUnavailableView(
                    "Openings unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not load the opening dataset.")
                )
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    @ViewBuilder
    private func content(session: OpeningDemoSession) -> some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 24) {
                moveTreePanel(session: session)
                VStack(alignment: .leading, spacing: 16) {
                    header
                    machineCard(session: session)
                    moveHistoryCard(session: session)
                    presetLines(session: session)
                    plyReportCard(session: session)
                    inspectorCard(session: session)
                }
                .frame(maxWidth: 360, alignment: .leading)
            }
            .padding(24)
            .navigationTitle("Opening Tree + Watcher")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SwiftXState Openings")
                .font(.title2.bold())
            Text("Base: `opening-move-tree` · Watcher: read-only supervisor")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func moveTreePanel(session: OpeningDemoSession) -> some View {
        GroupBox("Legal moves (tree edges)") {
            VStack(alignment: .leading, spacing: 8) {
                if session.atPlyLimit {
                    Text("10 plies reached — recognition scope ends here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if session.availableMoves.isEmpty {
                    Text("No outgoing edges from this node.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                        ForEach(session.availableMoves, id: \.self) { san in
                            Button(san) {
                                Task { await session.send(san: san) }
                            }
                            .buttonStyle(.bordered)
                            .font(.body.monospaced().bold())
                        }
                    }
                }

                Button("Reset line") {
                    Task { try? await session.reset() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 280)
    }

    private func machineCard(session: OpeningDemoSession) -> some View {
        GroupBox("Base machine") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("State") {
                    Text(session.snapshot.value.description)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Ply") {
                    Text("\(session.context.ply)")
                }
                LabeledContent("Node") {
                    Text(session.context.nodeId)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func moveHistoryCard(session: OpeningDemoSession) -> some View {
        GroupBox("Line played") {
            ScrollView {
                if session.moveHistory.isEmpty {
                    Text("Tap a SAN move to walk the tree.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.moveHistory.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  "))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 60)
        }
    }

    private func presetLines(session: OpeningDemoSession) -> some View {
        GroupBox("Sample lines") {
            VStack(alignment: .leading, spacing: 6) {
                presetButton("Sicilian Najdorf", moves: ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4", "Nf6", "Nc3", "a6"], session: session)
                presetButton("Ruy Lopez", moves: ["e4", "e5", "Nf3", "Nc6", "Bb5"], session: session)
                presetButton("Queen's Gambit", moves: ["d4", "d5", "c4", "e6", "Nc3", "Nf6", "Bg5", "Be7", "e3", "O-O"], session: session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func presetButton(_ title: String, moves: [String], session: OpeningDemoSession) -> some View {
        Button(title) {
            Task { try? await session.playLine(moves) }
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    private func plyReportCard(session: OpeningDemoSession) -> some View {
        GroupBox("Watcher · PlyReport") {
            ScrollView {
                if let report = session.latestReport {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ply \(report.ply): \(report.move)")
                            .font(.headline)

                        if let primary = report.primaryOpening {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(primary.displayPath)
                                    Text(primary.eco)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                        } else {
                            Text("No named opening at this depth")
                                .foregroundStyle(.secondary)
                        }

                        if !report.alsoTransposedInto.isEmpty {
                            Divider()
                            Text("Also transposed into")
                                .font(.caption.bold())
                            ForEach(report.alsoTransposedInto, id: \.self) { label in
                                Text("· \(label.displayPath) (\(label.eco))")
                                    .font(.caption)
                            }
                        }

                        if !report.oneMoveAway.isEmpty {
                            Divider()
                            Text("One move away")
                                .font(.caption.bold())
                            ForEach(Array(report.oneMoveAway.enumerated()), id: \.offset) { _, candidate in
                                Text("· \(candidate.move) → \(candidate.name)\(candidate.variation.isEmpty ? "" : " / \(candidate.variation)")")
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Make a move to see recognition and transposition probes.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 500
            
            )
        }
    }

    private func inspectorCard(session: OpeningDemoSession) -> some View {
        GroupBox("Stately Inspector") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Status") {
                    Text(session.connectionStatus)
                }
                LabeledContent("Machine") {
                    Text(OpeningMoveTreeMachine.id)
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
