import Foundation

/// Stable actor child ids for Stately (`square.e4`, `piece.wPe2`, …).
enum BoardActorIds {
    static func square(row: Int, col: Int) -> String {
        "square.\(file(col))\(row + 1)"
    }

    static func square(_ sq: Square) -> String {
        square(row: sq.row, col: sq.col)
    }

    static func square(_ coord: String) -> String {
        "square.\(coord)"
    }

    static func coord(_ square: Square) -> String {
        "\(file(square.col))\(square.row + 1)"
    }

    static func piece(id: String) -> String {
        "piece.\(id)"
    }

    static func file(_ col: Int) -> String {
        ["a", "b", "c", "d", "e", "f", "g", "h"][col]
    }

    static func parseCoord(_ coord: String) -> Square? {
        guard coord.count == 2,
              let col = ["a", "b", "c", "d", "e", "f", "g", "h"].firstIndex(of: String(coord.prefix(1))),
              let row = Int(coord.suffix(1)),
              row >= 1, row <= 8 else {
            return nil
        }
        return Square(row: row - 1, col: col)
    }
}

struct PieceInstanceId: Sendable, Equatable, Codable {
    let token: String

    static func make(color: PieceColor, kind: PieceKind, home: Square) -> PieceInstanceId {
        let prefix = color == .white ? "w" : "b"
        let kindLetter: String
        switch kind {
        case .pawn: kindLetter = "P"
        case .rook: kindLetter = "R"
        case .knight: kindLetter = "N"
        case .bishop: kindLetter = "B"
        case .queen: kindLetter = "Q"
        case .king: kindLetter = "K"
        }
        return PieceInstanceId(token: "\(prefix)\(kindLetter)\(BoardActorIds.file(home.col))\(home.row + 1)")
    }
}

struct BoardLayoutSeed: Sendable, Equatable, Codable {
    struct SquareSeed: Sendable, Equatable, Codable {
        let coord: String
        let occupantId: String?
    }

    struct PieceSeed: Sendable, Equatable, Codable {
        let id: String
        let kind: PieceKind
        let color: PieceColor
        let square: String
    }

    let squares: [SquareSeed]
    let pieces: [PieceSeed]

    static func standard() -> BoardLayoutSeed {
        var squares: [SquareSeed] = []
        var pieces: [PieceSeed] = []

        for row in 0..<Board.size {
            for col in 0..<Board.size {
                let coord = "\(BoardActorIds.file(col))\(row + 1)"
                squares.append(SquareSeed(coord: coord, occupantId: nil))
            }
        }

        let board = Board.standard()
        for row in 0..<Board.size {
            for col in 0..<Board.size {
                let sq = Square(row: row, col: col)
                guard let piece = board[sq] else { continue }
                let home = sq
                let id = PieceInstanceId.make(color: piece.color, kind: piece.kind, home: home).token
                let coord = BoardActorIds.coord(sq)
                if let index = squares.firstIndex(where: { $0.coord == coord }) {
                    squares[index] = SquareSeed(coord: coord, occupantId: id)
                }
                pieces.append(PieceSeed(id: id, kind: piece.kind, color: piece.color, square: coord))
            }
        }

        return BoardLayoutSeed(squares: squares, pieces: pieces)
    }

    var squareChildIds: [String] {
        squares.map { BoardActorIds.square($0.coord) }
    }

    var pieceChildIds: [String] {
        pieces.map { BoardActorIds.piece(id: $0.id) }
    }

    var allChildIds: [String] {
        squareChildIds + pieceChildIds
    }
}