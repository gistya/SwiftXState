import ChessKit
import Foundation

enum ChessSAN {
    static func format(
        move: ChessMove,
        board: Board,
        turn: PieceColor,
        castlingRights: CastlingRights
    ) -> String? {
        let fen = fenString(board: board, turn: turn, castlingRights: castlingRights)
        guard let position = Position(fen: fen) else { return nil }
        var ckBoard = ChessKit.Board(position: position)
        let from = ChessKit.Square(BoardActorIds.coord(move.from))
        let to = ChessKit.Square(BoardActorIds.coord(move.to))
        guard let applied = ckBoard.move(pieceAt: from, to: to) else { return nil }
        return applied.san
    }

    private static func fenString(
        board: Board,
        turn: PieceColor,
        castlingRights: CastlingRights
    ) -> String {
        var ranks: [String] = []
        for row in (0..<Board.size).reversed() {
            var rank = ""
            var empty = 0
            for col in 0..<Board.size {
                let square = Square(row: row, col: col)
                if let piece = board[square] {
                    if empty > 0 {
                        rank.append(String(empty))
                        empty = 0
                    }
                    rank.append(fenSymbol(piece))
                } else {
                    empty += 1
                }
            }
            if empty > 0 { rank.append(String(empty)) }
            ranks.append(rank)
        }

        let placement = ranks.joined(separator: "/")
        let active = turn == .white ? "w" : "b"
        var castling = ""
        if castlingRights.whiteKingside { castling.append("K") }
        if castlingRights.whiteQueenside { castling.append("Q") }
        if castlingRights.blackKingside { castling.append("k") }
        if castlingRights.blackQueenside { castling.append("q") }
        if castling.isEmpty { castling = "-" }
        return "\(placement) \(active) \(castling) - 0 1"
    }

    private static func fenSymbol(_ piece: Piece) -> String {
        let letter: String
        switch piece.kind {
        case .pawn: letter = "p"
        case .rook: letter = "r"
        case .knight: letter = "n"
        case .bishop: letter = "b"
        case .queen: letter = "q"
        case .king: letter = "k"
        }
        return piece.color == .white ? letter.uppercased() : letter
    }
}