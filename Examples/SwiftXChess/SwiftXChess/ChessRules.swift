import Foundation
import SwiftXState

enum ChessRules {
    static func pendingMove(from args: ActionArgs<ChessContext>) -> ChessMove? {
        guard args.context.replaySession == nil,
              args.context.pendingPromotion == nil,
              let event = ChessEvent.parse(args.event),
              case let .tap(to) = event,
              let from = args.context.selected else {
            return nil
        }
        return legalMove(
            from: from,
            to: to,
            board: args.context.board,
            turn: args.context.turn,
            castlingRights: args.context.castlingRights
        )
    }

    static func forfeitsWhiteKingside(_ move: ChessMove) -> Bool {
        if move.piece == .king, move.from == Square(row: 0, col: 4) { return true }
        if move.piece == .rook, move.from == Square(row: 0, col: 7) { return true }
        if move.capture == .rook, move.to == Square(row: 0, col: 7) { return true }
        if move.castle == .kingside, move.from == Square(row: 0, col: 4) { return true }
        return false
    }

    static func forfeitsWhiteQueenside(_ move: ChessMove) -> Bool {
        if move.piece == .king, move.from == Square(row: 0, col: 4) { return true }
        if move.piece == .rook, move.from == Square(row: 0, col: 0) { return true }
        if move.capture == .rook, move.to == Square(row: 0, col: 0) { return true }
        if move.castle == .queenside, move.from == Square(row: 0, col: 4) { return true }
        return false
    }

    static func forfeitsBlackKingside(_ move: ChessMove) -> Bool {
        if move.piece == .king, move.from == Square(row: 7, col: 4) { return true }
        if move.piece == .rook, move.from == Square(row: 7, col: 7) { return true }
        if move.capture == .rook, move.to == Square(row: 7, col: 7) { return true }
        if move.castle == .kingside, move.from == Square(row: 7, col: 4) { return true }
        return false
    }

    static func forfeitsBlackQueenside(_ move: ChessMove) -> Bool {
        if move.piece == .king, move.from == Square(row: 7, col: 4) { return true }
        if move.piece == .rook, move.from == Square(row: 7, col: 0) { return true }
        if move.capture == .rook, move.to == Square(row: 7, col: 0) { return true }
        if move.castle == .queenside, move.from == Square(row: 7, col: 4) { return true }
        return false
    }

    static func handleTap(_ context: inout ChessContext, at square: Square) {
        guard context.outcome == nil, context.pendingPromotion == nil else { return }

        if let selected = context.selected {
            if selected == square {
                context.selected = nil
                return
            }
            if let move = legalMove(
                from: selected,
                to: square,
                board: context.board,
                turn: context.turn,
                castlingRights: context.castlingRights
            ) {
                if move.piece == .pawn, isPromotionSquare(move.to, color: context.turn) {
                    context.pendingPromotion = PendingPromotion(from: selected, to: square)
                    context.selected = nil
                    return
                }
                completeMove(&context, move: move)
                return
            }
        }

        if let piece = context.board[square], piece.color == context.turn {
            context.selected = square
        } else {
            context.selected = nil
        }
    }

    static func handlePromotion(_ context: inout ChessContext, piece kind: PieceKind) {
        guard context.outcome == nil,
              let pending = context.pendingPromotion,
              PieceKind.promotionChoices.contains(kind) else {
            return
        }

        guard var move = legalMove(
            from: pending.from,
            to: pending.to,
            board: context.board,
            turn: context.turn,
            castlingRights: context.castlingRights
        ) else {
            context.pendingPromotion = nil
            return
        }

        move.promotion = kind
        context.pendingPromotion = nil
        completeMove(&context, move: move)
    }

    static func legalMove(
        from: Square,
        to: Square,
        board: Board,
        turn: PieceColor,
        castlingRights: CastlingRights
    ) -> ChessMove? {
        guard board.isOnBoard(from), board.isOnBoard(to), from != to,
              let piece = board[from], piece.color == turn else {
            return nil
        }

        let target = board[to]
        if let target, target.color == piece.color {
            return nil
        }

        let castle = detectCastle(from: from, to: to, piece: piece, board: board, rights: castlingRights)
        guard pseudoLegal(
            from: from,
            to: to,
            piece: piece,
            board: board,
            castle: castle
        ) else {
            return nil
        }

        var trial = board
        let trialMove = ChessMove(
            from: from,
            to: to,
            piece: piece.kind,
            capture: target?.kind,
            castle: castle
        )
        guard apply(trialMove, to: &trial) else { return nil }
        if isKingInCheck(color: turn, board: trial) {
            return nil
        }

        return ChessMove(
            from: from,
            to: to,
            piece: piece.kind,
            capture: target?.kind,
            promotion: nil,
            castle: castle
        )
    }

    static func apply(_ move: ChessMove, to board: inout Board) -> Bool {
        guard let piece = board[move.from] else { return false }

        if let castle = move.castle {
            applyCastle(move, piece: piece, castle: castle, to: &board)
        } else {
            let promotedKind = move.promotion ?? piece.kind
            board[move.to] = Piece(kind: promotedKind, color: piece.color)
            board[move.from] = nil
        }
        return true
    }

    static func evaluateOutcome(
        board: Board,
        turn: PieceColor,
        castlingRights: CastlingRights
    ) -> GameOutcome? {
        if hasAnyLegalMove(board: board, turn: turn, castlingRights: castlingRights) {
            return nil
        }
        if isKingInCheck(color: turn, board: board) {
            return turn == .white ? .checkmateBlack : .checkmateWhite
        }
        return .stalemate
    }

    static func hasAnyLegalMove(board: Board, turn: PieceColor, castlingRights: CastlingRights) -> Bool {
        for row in 0..<Board.size {
            for col in 0..<Board.size {
                let from = Square(row: row, col: col)
                guard let piece = board[from], piece.color == turn else { continue }
                for targetRow in 0..<Board.size {
                    for targetCol in 0..<Board.size {
                        let to = Square(row: targetRow, col: targetCol)
                        if legalMove(
                            from: from,
                            to: to,
                            board: board,
                            turn: turn,
                            castlingRights: castlingRights
                        ) != nil {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    static func isKingInCheck(color: PieceColor, board: Board) -> Bool {
        guard let kingSquare = board.kingSquare(for: color) else { return false }
        return isSquareAttacked(kingSquare, by: color.opposite, board: board)
    }

    static func isSquareAttacked(_ square: Square, by attacker: PieceColor, board: Board) -> Bool {
        for row in 0..<Board.size {
            for col in 0..<Board.size {
                let from = Square(row: row, col: col)
                guard let piece = board[from], piece.color == attacker else { continue }
                if pseudoLegal(from: from, to: square, piece: piece, board: board, castle: nil) {
                    return true
                }
            }
        }
        return false
    }

    private static func completeMove(_ context: inout ChessContext, move: ChessMove) {
        guard apply(move, to: &context.board) else { return }
        updateCastlingRights(move: move, rights: &context.castlingRights)
        context.moveHistory.append(move)
        context.selected = nil
        context.turn = context.turn.opposite
        context.outcome = evaluateOutcome(
            board: context.board,
            turn: context.turn,
            castlingRights: context.castlingRights
        )
    }

    private static func isPromotionSquare(_ square: Square, color: PieceColor) -> Bool {
        color == .white ? square.row == 7 : square.row == 0
    }

    private static func detectCastle(
        from: Square,
        to: Square,
        piece: Piece,
        board: Board,
        rights: CastlingRights
    ) -> CastleSide? {
        guard piece.kind == .king, from.row == to.row, abs(to.col - from.col) == 2 else {
            return nil
        }

        let kingside = to.col > from.col
        let side: CastleSide = kingside ? .kingside : .queenside
        let row = piece.color == .white ? 0 : 7

        guard from.row == row, from.col == 4 else { return nil }

        switch (piece.color, side) {
        case (.white, .kingside):
            guard rights.whiteKingside, to.col == 6 else { return nil }
            guard board[Square(row: row, col: 5)] == nil,
                  board[Square(row: row, col: 6)] == nil,
                  board[Square(row: row, col: 7)]?.kind == .rook,
                  board[Square(row: row, col: 7)]?.color == .white else { return nil }
            guard !isKingInCheck(color: .white, board: board),
                  !isSquareAttacked(Square(row: row, col: 5), by: .black, board: board),
                  !isSquareAttacked(Square(row: row, col: 6), by: .black, board: board) else { return nil }
            return .kingside

        case (.white, .queenside):
            guard rights.whiteQueenside, to.col == 2 else { return nil }
            guard board[Square(row: row, col: 1)] == nil,
                  board[Square(row: row, col: 2)] == nil,
                  board[Square(row: row, col: 3)] == nil,
                  board[Square(row: row, col: 0)]?.kind == .rook,
                  board[Square(row: row, col: 0)]?.color == .white else { return nil }
            guard !isKingInCheck(color: .white, board: board),
                  !isSquareAttacked(Square(row: row, col: 3), by: .black, board: board),
                  !isSquareAttacked(Square(row: row, col: 2), by: .black, board: board) else { return nil }
            return .queenside

        case (.black, .kingside):
            guard rights.blackKingside, to.col == 6 else { return nil }
            guard board[Square(row: row, col: 5)] == nil,
                  board[Square(row: row, col: 6)] == nil,
                  board[Square(row: row, col: 7)]?.kind == .rook,
                  board[Square(row: row, col: 7)]?.color == .black else { return nil }
            guard !isKingInCheck(color: .black, board: board),
                  !isSquareAttacked(Square(row: row, col: 5), by: .white, board: board),
                  !isSquareAttacked(Square(row: row, col: 6), by: .white, board: board) else { return nil }
            return .kingside

        case (.black, .queenside):
            guard rights.blackQueenside, to.col == 2 else { return nil }
            guard board[Square(row: row, col: 1)] == nil,
                  board[Square(row: row, col: 2)] == nil,
                  board[Square(row: row, col: 3)] == nil,
                  board[Square(row: row, col: 0)]?.kind == .rook,
                  board[Square(row: row, col: 0)]?.color == .black else { return nil }
            guard !isKingInCheck(color: .black, board: board),
                  !isSquareAttacked(Square(row: row, col: 3), by: .white, board: board),
                  !isSquareAttacked(Square(row: row, col: 2), by: .white, board: board) else { return nil }
            return .queenside
        }
    }

    private static func applyCastle(
        _ move: ChessMove,
        piece: Piece,
        castle: CastleSide,
        to board: inout Board
    ) {
        let row = piece.color == .white ? 0 : 7
        board[move.from] = nil

        switch castle {
        case .kingside:
            board[Square(row: row, col: 6)] = piece
            if let rook = board[Square(row: row, col: 7)] {
                board[Square(row: row, col: 5)] = rook
                board[Square(row: row, col: 7)] = nil
            }
        case .queenside:
            board[Square(row: row, col: 2)] = piece
            if let rook = board[Square(row: row, col: 0)] {
                board[Square(row: row, col: 3)] = rook
                board[Square(row: row, col: 0)] = nil
            }
        }
    }

    private static func updateCastlingRights(move: ChessMove, rights: inout CastlingRights) {
        if forfeitsWhiteKingside(move) { rights.whiteKingside = false }
        if forfeitsWhiteQueenside(move) { rights.whiteQueenside = false }
        if forfeitsBlackKingside(move) { rights.blackKingside = false }
        if forfeitsBlackQueenside(move) { rights.blackQueenside = false }
    }

    private static func pseudoLegal(
        from: Square,
        to: Square,
        piece: Piece,
        board: Board,
        castle: CastleSide?
    ) -> Bool {
        if castle != nil {
            return true
        }

        let rowDelta = to.row - from.row
        let colDelta = to.col - from.col
        let absRow = abs(rowDelta)
        let absCol = abs(colDelta)
        let target = board[to]

        switch piece.kind {
        case .pawn:
            let direction = piece.color == .white ? 1 : -1
            let startRow = piece.color == .white ? 1 : 6
            if colDelta == 0 {
                if rowDelta == direction, target == nil { return true }
                if from.row == startRow, rowDelta == 2 * direction,
                   board[Square(row: from.row + direction, col: from.col)] == nil,
                   target == nil {
                    return true
                }
                return false
            }
            if absCol == 1, rowDelta == direction, target?.color == piece.color.opposite {
                return true
            }
            return false

        case .rook:
            if rowDelta != 0 && colDelta != 0 { return false }
            return pathIsClear(from: from, to: to, board: board)

        case .bishop:
            if absRow != absCol { return false }
            return pathIsClear(from: from, to: to, board: board)

        case .queen:
            if rowDelta != 0 && colDelta != 0 && absRow != absCol { return false }
            return pathIsClear(from: from, to: to, board: board)

        case .knight:
            return (absRow == 2 && absCol == 1) || (absRow == 1 && absCol == 2)

        case .king:
            return absRow <= 1 && absCol <= 1
        }
    }

    private static func pathIsClear(from: Square, to: Square, board: Board) -> Bool {
        let rowStep = (to.row - from.row).signum()
        let colStep = (to.col - from.col).signum()
        var row = from.row + rowStep
        var col = from.col + colStep
        while row != to.row || col != to.col {
            if board[Square(row: row, col: col)] != nil {
                return false
            }
            row += rowStep
            col += colStep
        }
        return true
    }
}

private extension Int {
    func signum() -> Int {
        if self > 0 { return 1 }
        if self < 0 { return -1 }
        return 0
    }
}
