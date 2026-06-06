import SwiftUI
import SwiftXChessOpenings

/// Read-only opening panel: tree-legal moves and watcher recognition (no move buttons).
struct OpeningPanelView: View {
    let availableMoves: [String]
    let latestReport: PlyReport?
    let openingActive: Bool
    let atPlyLimit: Bool
    let moveHistory: [String]

    /// When true, the expanded panel grows to fill the available vertical space (e.g. a tall iPad
    /// sidebar) instead of capping at `expandedHeight`. Defaults to the macOS behavior.
    var fillsAvailableHeight: Bool = false

    @State private var isExpanded: Bool

    private let collapsedHeight: CGFloat = 96
    private let expandedHeight: CGFloat = 280

    init(
        availableMoves: [String],
        latestReport: PlyReport?,
        openingActive: Bool,
        atPlyLimit: Bool,
        moveHistory: [String],
        fillsAvailableHeight: Bool = false,
        startsExpanded: Bool = false
    ) {
        self.availableMoves = availableMoves
        self.latestReport = latestReport
        self.openingActive = openingActive
        self.atPlyLimit = atPlyLimit
        self.moveHistory = moveHistory
        self.fillsAvailableHeight = fillsAvailableHeight
        _isExpanded = State(initialValue: startsExpanded)
    }

    private var scrollHeight: CGFloat? {
        guard isExpanded else { return collapsedHeight }
        return fillsAvailableHeight ? nil : expandedHeight
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                panelHeader

                ScrollView {
                    panelContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .frame(height: scrollHeight)
                .frame(maxHeight: fillsAvailableHeight && isExpanded ? .infinity : nil)
            }
        } label: {
            HStack {
                Text("Opening")
                Spacer()
                if isExpanded {
                    Button("Close") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = false
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    private var panelHeader: some View {
        HStack {
            Text(collapsedSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if !isExpanded {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isExpanded else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = true
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            treeMovesSection
            Divider()
            recognitionSection
        }
    }

    private var collapsedSummary: String {
        if atPlyLimit { return "Opening phase complete" }
        if !openingActive { return "Off-book — watcher dormant" }
        if let primary = latestReport?.primaryOpening {
            return primary.displayPath
        }
        if !availableMoves.isEmpty {
            return "\(availableMoves.count) legal tree moves"
        }
        return "Tap to expand opening details"
    }

    private var treeMovesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tree-legal next moves")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if atPlyLimit {
                Text("Opening phase complete (10 plies).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !openingActive {
                Text("Off-book — opening watcher dormant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if availableMoves.isEmpty {
                Text("No outgoing edges from this node.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 44), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(availableMoves, id: \.self) { san in
                        Text(san)
                            .font(.caption.monospaced().bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if !moveHistory.isEmpty {
                Text(moveHistory.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recognition")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if let report = latestReport {
                Text("Ply \(report.ply): \(report.move)")
                    .font(.subheadline.bold())

                if let primary = report.primaryOpening {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(primary.displayPath)
                                .fixedSize(horizontal: false, vertical: true)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !report.alsoTransposedInto.isEmpty {
                    Text("Also transposed into")
                        .font(.caption.bold())
                        .padding(.top, 4)
                    ForEach(report.alsoTransposedInto, id: \.self) { label in
                        Text("· \(label.displayPath) (\(label.eco))")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !report.oneMoveAway.isEmpty {
                    Text("One move away")
                        .font(.caption.bold())
                        .padding(.top, 4)
                    ForEach(Array(report.oneMoveAway.enumerated()), id: \.offset) { _, candidate in
                        Text("· \(candidate.move) → \(candidate.name)\(candidate.variation.isEmpty ? "" : " / \(candidate.variation)")")
                            .font(.caption.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if openingActive {
                Text("Play on the board to see opening recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Opening watcher is dormant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}