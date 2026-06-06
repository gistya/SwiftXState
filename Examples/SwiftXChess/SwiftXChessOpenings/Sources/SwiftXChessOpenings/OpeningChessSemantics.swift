import ChessKit
import Foundation

enum OpeningChessSemantics {
    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    static func normalizeFEN(_ fen: String) -> FENKey {
        let parts = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return fen }
        // Dataset keys were built with python-chess, which leaves en passant as `-`
        // unless a capture is immediately available. ChessKit always records the target
        // square; stripping ep keeps watcher lookups aligned with `fenLabels`.
        return "\(parts[0]) \(parts[1]) \(parts[2]) -"
    }

    static func normalizeFEN(_ position: Position) -> FENKey {
        normalizeFEN(position.fen)
    }

    static func makeBoard(fen: String = startFEN) -> Board? {
        guard let position = Position(fen: fen) else { return nil }
        return Board(position: position)
    }

    @discardableResult
    static func apply(san: String, to board: inout Board) -> Bool {
        guard let move = Move(san: san, position: board.position) else { return false }
        return board.move(pieceAt: move.start, to: move.end) != nil
    }

    /// All legal SAN moves from the current position.
    static func legalSANMoves(on board: Board) -> [String] {
        var moves: [String] = []
        let turn = board.position.sideToMove
        for square in Square.allCases {
            guard let piece = board.position.piece(at: square), piece.color == turn else {
                continue
            }
            for destination in board.legalMoves(forPieceAt: square) {
                var trial = board
                if let applied = trial.move(pieceAt: square, to: destination) {
                    moves.append(applied.san)
                }
            }
        }
        return Array(Set(moves)).sorted()
    }
}