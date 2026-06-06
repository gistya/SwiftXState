import Foundation
import SwiftXState

struct BoardInspectorContext: Sendable, Equatable, Codable {
    var occupants: [String: String]
    var boardGrid: [String]
    let layout: BoardLayoutSeed

    static func initial(layout: BoardLayoutSeed) -> BoardInspectorContext {
        var occupants: [String: String] = [:]
        for square in layout.squares {
            if let occupantId = square.occupantId {
                occupants[square.coord] = occupantId
            }
        }
        return BoardInspectorContext(
            occupants: occupants,
            boardGrid: BoardInspectorGrid.format(occupants: occupants),
            layout: layout
        )
    }

    mutating func refreshBoardGrid() {
        boardGrid = BoardInspectorGrid.format(occupants: occupants)
    }
}

enum BoardInspectorGrid {
    static func format(occupants: [String: String]) -> [String] {
        var lines: [String] = []
        for rank in (1...Board.size).reversed() {
            var cells: [String] = []
            for col in 0..<Board.size {
                let coord = "\(BoardActorIds.file(col))\(rank)"
                let cell = occupants[coord].map(pieceSymbol(for:)) ?? "·"
                cells.append(cell)
            }
            lines.append("\(rank) \(cells.joined(separator: " "))")
        }
        lines.append("  a b c d e f g h")
        return lines
    }

    private static func pieceSymbol(for pieceId: String) -> String {
        guard let kind = pieceId.dropFirst().first else { return "?" }
        let upper = kind.uppercased()
        if pieceId.hasPrefix("w") {
            return upper
        }
        return upper.lowercased()
    }
}

enum BoardInspectorEvent {
    static func parseSquareClear(_ event: any Eventable) -> String? {
        let prefix = "SQUARE.CLEAR."
        guard event.type.hasPrefix(prefix) else { return nil }
        return String(event.type.dropFirst(prefix.count))
    }

    static func parseSquareOccupy(_ event: any Eventable) -> (coord: String, pieceId: String)? {
        let prefix = "SQUARE.OCCUPY."
        guard event.type.hasPrefix(prefix) else { return nil }
        let remainder = String(event.type.dropFirst(prefix.count))
        let parts = remainder.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

enum BoardInspectorSync {
    /// `SQUARE.OCCUPY.<coord>.<type>.<instance>` — the piece *type* (`wP`, `bN`, …) is its own
    /// dotted segment so the `.pieces` board can route to the matching piece state via a
    /// `SQUARE.OCCUPY.<coord>.<type>.*` wildcard. The `.occupancy` board ignores the extra segments.
    static func occupyEvent(coord: String, pieceId: String) -> Event {
        let type = String(pieceId.prefix(2))
        let instance = String(pieceId.dropFirst(2))
        return Event("SQUARE.OCCUPY.\(coord).\(type).\(instance)")
    }

    static func events(occupants: [String: String], layout: BoardLayoutSeed) -> [Event] {
        layout.squares.map { square in
            if let pieceId = occupants[square.coord] {
                occupyEvent(coord: square.coord, pieceId: pieceId)
            } else {
                Event("SQUARE.CLEAR.\(square.coord)")
            }
        }
    }

    static func apply(_ event: any Eventable, to context: inout BoardInspectorContext) {
        if let coord = BoardInspectorEvent.parseSquareClear(event) {
            context.occupants.removeValue(forKey: coord)
            context.refreshBoardGrid()
            return
        }
        if let occupy = BoardInspectorEvent.parseSquareOccupy(event) {
            context.occupants[occupy.coord] = occupy.pieceId
            context.refreshBoardGrid()
        }
    }

    static func inspectorEvent(for command: GameWatcherCommand) -> Event? {
        switch command {
        case let .squareClear(coord):
            Event("SQUARE.CLEAR.\(coord)")
        case let .squareOccupy(coord, pieceId):
            occupyEvent(coord: coord, pieceId: pieceId)
        case .pieceMoveTo, .pieceCaptured:
            nil
        }
    }
}

/// Two ways to visualize the board as a live statechart:
/// - `.occupancy`: each square is `{ empty | occupied }` (2 states).
/// - `.pieces`: each square enumerates the piece on it — `empty` + the 12 piece types — as a
///   **hub-and-spoke** through `empty` (captures/promotions pass through `empty`, mirroring play).
public enum BoardMode: String, Sendable, CaseIterable {
    case occupancy
    case pieces
}

enum BoardInspectorMachine {
    /// The 12 piece types, white then black, in P N B R Q K order.
    static let pieceTypes = ["wP", "wN", "wB", "wR", "wQ", "wK", "bP", "bN", "bB", "bR", "bQ", "bK"]

    static let occupancyId = "board-occupancy"
    static let piecesId = "board-pieces"
    static func id(_ mode: BoardMode) -> String { mode == .occupancy ? occupancyId : piecesId }
    static func childId(_ mode: BoardMode) -> String { id(mode) }

    static func make(mode: BoardMode = .occupancy, layout: BoardLayoutSeed = .standard()) -> StateMachine<BoardInspectorContext> {
        let context = BoardInspectorContext.initial(layout: layout)

        var squares: [String: StateNodeConfig<BoardInspectorContext>] = [:]
        for square in layout.squares {
            let coord = square.coord
            squares[coord] = mode == .occupancy
                ? occupancySquare(coord: coord, occupied: context.occupants[coord] != nil)
                : piecesSquare(coord: coord, pieceId: context.occupants[coord])
        }

        return createMachine(
            MachineConfig(
                id: id(mode),
                context: context,
                states: squares,
                type: .parallel,
                description: mode == .occupancy
                    ? "Live 8×8 board — 64 parallel { empty | occupied } squares"
                    : "Live 8×8 board — 64 squares enumerating their piece (hub-and-spoke through empty)"
            )
        )
    }

    private static func occupancySquare(coord: String, occupied: Bool) -> StateNodeConfig<BoardInspectorContext> {
        StateNodeConfig(
            initial: occupied ? "occupied" : "empty",
            states: [
                "empty": StateNodeConfig(on: ["SQUARE.OCCUPY.\(coord).*": .to("occupied")]),
                "occupied": StateNodeConfig(on: ["SQUARE.CLEAR.\(coord)": .to("empty")]),
            ]
        )
    }

    private static func piecesSquare(coord: String, pieceId: String?) -> StateNodeConfig<BoardInspectorContext> {
        // From `empty`, occupy → the matching piece type; from any piece, clear → `empty`.
        var emptyOn: [String: TransitionInput<BoardInspectorContext>] = [:]
        for type in pieceTypes {
            emptyOn["SQUARE.OCCUPY.\(coord).\(type).*"] = .to(type)
        }
        var states: [String: StateNodeConfig<BoardInspectorContext>] = ["empty": StateNodeConfig(on: emptyOn)]
        for type in pieceTypes {
            states[type] = StateNodeConfig(on: ["SQUARE.CLEAR.\(coord)": .to("empty")])
        }
        let initial = pieceId.map { String($0.prefix(2)) }.flatMap { pieceTypes.contains($0) ? $0 : nil } ?? "empty"
        return StateNodeConfig(initial: initial, states: states)
    }

    /// Drop into `GraphStyle.nodeLayoutOverride`. Lays the board-inspector machines (both modes)
    /// out as 8×8 grids, and arranges each square's inner states (alphabetical for occupancy; a
    /// compact hub-and-spoke with `empty` centered for pieces). Only affects board machines.
    /// Cell pitch and inner gaps are kept just larger than the node size so option-nodes stay
    /// large (rather than tiny specks) when the whole board is zoomed to fit.
    static func gridLayoutOverride(occupancyCell: CGFloat = 280, piecesCell: CGFloat = 560) -> @Sendable (String, String) -> CGPoint? {
        { nodeID, relativePath in
            let parts = relativePath.split(separator: ".").map(String.init)

            if nodeID.hasPrefix("\(occupancyId).") {
                if parts.count == 2 {  // empty/occupied — alphabetical
                    return CGPoint(x: CGFloat((parts[1] == "empty" ? 0 : 1) * 134), y: 0)
                }
                if parts.count == 1, let center = gridCenter(parts[0], cell: occupancyCell) { return center }
            } else if nodeID.hasPrefix("\(piecesId).") {
                if parts.count == 2 { return piecesSubPosition(parts[1]) }
                if parts.count == 1, let center = gridCenter(parts[0], cell: piecesCell) { return center }
            }
            return nil
        }
    }

    /// Local placement of a square's states in `.pieces` mode: `empty` is the hub above a
    /// 4-wide × 3-tall grid of the 12 piece types (so edges fan out from the hub). Gaps are
    /// kept tight (~node size) to maximize node size at board-fit zoom.
    private static func piecesSubPosition(_ state: String) -> CGPoint {
        let colGap: CGFloat = 130, rowGap: CGFloat = 78
        if state == "empty" {
            return CGPoint(x: 1.5 * colGap, y: -rowGap * 1.3)  // hub, centered above the 4×3 grid
        }
        guard let index = pieceTypes.firstIndex(of: state) else { return CGPoint(x: 0, y: 0) }
        return CGPoint(x: CGFloat(index % 4) * colGap, y: CGFloat(index / 4) * rowGap)
    }

    private static func gridCenter(_ coord: String, cell: CGFloat) -> CGPoint? {
        guard coord.count == 2 else { return nil }
        let chars = Array(coord)
        guard let fileIndex = "abcdefgh".firstIndex(of: chars[0]),
              let rank = chars[1].wholeNumberValue, (1...8).contains(rank) else { return nil }
        let col = "abcdefgh".distance(from: "abcdefgh".startIndex, to: fileIndex)
        return CGPoint(x: CGFloat(col) * cell, y: CGFloat(8 - rank) * cell)
    }
}