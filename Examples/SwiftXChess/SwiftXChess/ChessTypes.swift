import Foundation
import SwiftXState

// MARK: - Board primitives

struct Square: Sendable, Equatable, Hashable, Codable {
    let row: Int
    let col: Int
}

enum PieceKind: String, Sendable, Equatable, Codable, CaseIterable {
    case pawn, rook, knight, bishop, queen, king

    static let promotionChoices: [PieceKind] = [.queen, .rook, .bishop, .knight]
}

enum PieceColor: String, Sendable, Equatable, Codable {
    case white, black

    var opposite: PieceColor {
        self == .white ? .black : .white
    }
}

enum CastleSide: String, Sendable, Equatable, Codable {
    case kingside
    case queenside
}

struct Piece: Sendable, Equatable, Codable {
    let kind: PieceKind
    let color: PieceColor
}

struct ChessMove: Sendable, Equatable, Codable {
    let from: Square
    let to: Square
    let piece: PieceKind
    let capture: PieceKind?
    var promotion: PieceKind?
    var castle: CastleSide?

    init(
        from: Square,
        to: Square,
        piece: PieceKind,
        capture: PieceKind? = nil,
        promotion: PieceKind? = nil,
        castle: CastleSide? = nil
    ) {
        self.from = from
        self.to = to
        self.piece = piece
        self.capture = capture
        self.promotion = promotion
        self.castle = castle
    }
}

struct CastlingRights: Sendable, Equatable, Codable {
    var whiteKingside: Bool
    var whiteQueenside: Bool
    var blackKingside: Bool
    var blackQueenside: Bool

    static let initial = CastlingRights(
        whiteKingside: true,
        whiteQueenside: true,
        blackKingside: true,
        blackQueenside: true
    )
}

struct PendingPromotion: Sendable, Equatable, Codable {
    let from: Square
    let to: Square
}

enum GameOutcome: String, Sendable, Equatable, Codable {
    case checkmateWhite
    case checkmateBlack
    case stalemate
}

struct Board: Sendable, Equatable, Codable {
    static let size = 8

    private var cells: [Piece?]

    init(cells: [Piece?] = Array(repeating: nil, count: size * size)) {
        self.cells = cells
    }

    static func standard() -> Board {
        var board = Board()
        let backRank: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for col in 0..<size {
            board[Square(row: 0, col: col)] = Piece(kind: backRank[col], color: .white)
            board[Square(row: 1, col: col)] = Piece(kind: .pawn, color: .white)
            board[Square(row: 6, col: col)] = Piece(kind: .pawn, color: .black)
            board[Square(row: 7, col: col)] = Piece(kind: backRank[col], color: .black)
        }
        return board
    }

    subscript(_ square: Square) -> Piece? {
        get {
            guard isOnBoard(square) else { return nil }
            return cells[square.row * Board.size + square.col]
        }
        set {
            guard isOnBoard(square) else { return }
            cells[square.row * Board.size + square.col] = newValue
        }
    }

    func isOnBoard(_ square: Square) -> Bool {
        (0..<Board.size).contains(square.row) && (0..<Board.size).contains(square.col)
    }

    func kingSquare(for color: PieceColor) -> Square? {
        for row in 0..<Board.size {
            for col in 0..<Board.size {
                let square = Square(row: row, col: col)
                if let piece = self[square], piece.kind == .king, piece.color == color {
                    return square
                }
            }
        }
        return nil
    }
}

// MARK: - Context & events

struct ChessLiveSnapshot: Sendable, Equatable, Codable {
    var board: Board
    var turn: PieceColor
    var selected: Square?
    var moveHistory: [ChessMove]
    var outcome: GameOutcome?
    var castlingRights: CastlingRights
    var pendingPromotion: PendingPromotion?
}

struct ChessContext: Sendable, Equatable, Codable {
    var board: Board
    var turn: PieceColor
    var selected: Square?
    var moveHistory: [ChessMove]
    var outcome: GameOutcome?
    var castlingRights: CastlingRights
    var pendingPromotion: PendingPromotion?
    var replaySession: ReplaySession?
    var replayStep: Int
    var liveSnapshot: ChessLiveSnapshot?

    static func initial() -> ChessContext {
        ChessContext(
            board: .standard(),
            turn: .white,
            selected: nil,
            moveHistory: [],
            outcome: nil,
            castlingRights: .initial,
            pendingPromotion: nil,
            replaySession: nil,
            replayStep: 0,
            liveSnapshot: nil
        )
    }

    mutating func captureLiveSnapshot() {
        liveSnapshot = ChessLiveSnapshot(
            board: board,
            turn: turn,
            selected: selected,
            moveHistory: moveHistory,
            outcome: outcome,
            castlingRights: castlingRights,
            pendingPromotion: pendingPromotion
        )
    }

    mutating func restoreLiveSnapshot() {
        guard let liveSnapshot else { return }
        board = liveSnapshot.board
        turn = liveSnapshot.turn
        selected = liveSnapshot.selected
        moveHistory = liveSnapshot.moveHistory
        outcome = liveSnapshot.outcome
        castlingRights = liveSnapshot.castlingRights
        pendingPromotion = liveSnapshot.pendingPromotion
        self.liveSnapshot = nil
    }

    var isReplayMode: Bool {
        replaySession != nil
    }

    var statusLine: String {
        if isReplayMode {
            let total = max((replaySession?.steps.count ?? 1) - 1, 0)
            return "Replay step \(replayStep)/\(total)"
        }
        if pendingPromotion != nil {
            return "\(turn.rawValue.capitalized) — choose promotion"
        }
        if let outcome {
            switch outcome {
            case .checkmateWhite: return "Checkmate — White wins"
            case .checkmateBlack: return "Checkmate — Black wins"
            case .stalemate: return "Stalemate — Draw"
            }
        }
        return "\(turn.rawValue.capitalized) to move"
    }
}

/// Typed event union — `EventIdentifying` gives each case its routing discriminant for free; the
/// hand-written `type` encoding (`TAP.<r>.<c>`, …) and `parse(_:)` are gone. Handlers/guards read the
/// payload off `args.event`. `Hashable` is synthesized (Square / PieceKind / Int are all Hashable).
enum ChessEvent: EventIdentifying {
    case tap(Square)
    case promote(PieceKind)
    case newGame
    case enterReplay
    case exitReplay
    case replayScrub(Int)

    static var _blank: ChessEvent { .newGame }
}
