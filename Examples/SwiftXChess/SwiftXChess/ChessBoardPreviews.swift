import SwiftUI

// MARK: - Fixtures

private enum ChessBoardPreviewFixtures {
    static var startingPosition: Board { .standard() }

    static var afterE4E5: Board {
        var board = Board.standard()
        board[Square(row: 1, col: 4)] = nil
        board[Square(row: 3, col: 4)] = Piece(kind: .pawn, color: .white)
        board[Square(row: 6, col: 4)] = nil
        board[Square(row: 4, col: 4)] = Piece(kind: .pawn, color: .black)
        return board
    }
}

// MARK: - Interactive host

/// Tap-to-move preview using the same rules as the app — best for tweaking tiles, shadows, and piece scale.
private struct ChessBoardPreviewHost: View {
    @State private var board = ChessBoardPreviewFixtures.startingPosition
    @State private var turn: PieceColor = .white
    @State private var selected: Square?
    @State private var pendingPromotion: PendingPromotion?
    @State private var castlingRights = CastlingRights.initial
    @State private var outcome: GameOutcome?

    var body: some View {
        ChessBoardView(
            board: board,
            selected: selected,
            pendingPromotion: pendingPromotion,
            promotionColor: turn,
            isInteractive: outcome == nil,
            onTap: handleTap,
            onPromote: handlePromotion
        )
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(previewChrome)
    }

    private func handleTap(row: Int, col: Int) {
        var context = makeContext()
        ChessRules.handleTap(&context, at: Square(row: row, col: col))
        apply(context)
    }

    private func handlePromotion(_ kind: PieceKind) {
        var context = makeContext()
        ChessRules.handlePromotion(&context, piece: kind)
        apply(context)
    }

    private func makeContext() -> ChessContext {
        ChessContext(
            board: board,
            turn: turn,
            selected: selected,
            moveHistory: [],
            outcome: outcome,
            castlingRights: castlingRights,
            pendingPromotion: pendingPromotion,
            replaySession: nil,
            replayStep: 0,
            liveSnapshot: nil
        )
    }

    private func apply(_ context: ChessContext) {
        board = context.board
        turn = context.turn
        selected = context.selected
        pendingPromotion = context.pendingPromotion
        castlingRights = context.castlingRights
        outcome = context.outcome
    }
}

// MARK: - Static board helper

private struct ChessBoardPreviewPanel: View {
    let board: Board
    var selected: Square? = nil
    var pendingPromotion: PendingPromotion? = nil
    var promotionColor: PieceColor = .white

    var body: some View {
        ChessBoardView(
            board: board,
            selected: selected,
            pendingPromotion: pendingPromotion,
            promotionColor: promotionColor,
            isInteractive: false,
            onTap: { _, _ in },
            onPromote: { _ in }
        )
        .padding(24)
        .background(previewChrome)
    }
}

private var previewChrome: some View {
    Color(red: 0.94, green: 0.94, blue: 0.96)
}

// MARK: - Previews

#Preview("Board · starting position") {
    ChessBoardPreviewPanel(board: ChessBoardPreviewFixtures.startingPosition)
}

#Preview("Board · e4 e5") {
    ChessBoardPreviewPanel(
        board: ChessBoardPreviewFixtures.afterE4E5,
        selected: Square(row: 1, col: 4)
    )
}

#Preview("Board · promotion picker") {
    ChessBoardPreviewPanel(
        board: promotionPreviewBoard(),
        pendingPromotion: PendingPromotion(
            from: Square(row: 1, col: 4),
            to: Square(row: 0, col: 4)
        ),
        promotionColor: .white
    )
}

#Preview("Board · interactive") {
    ChessBoardPreviewHost()
}

#Preview("Pieces · all assets") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            pieceGallery(title: "White", color: .white)
            pieceGallery(title: "Black", color: .black)
        }
        .padding(24)
    }
    .background(previewChrome)
}

@ViewBuilder
private func pieceGallery(title: String, color: PieceColor) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title)
            .font(.headline)
        HStack(spacing: 12) {
            ForEach(PieceKind.allCases, id: \.self) { kind in
                VStack(spacing: 4) {
                    ChessPieceView(piece: Piece(kind: kind, color: color), size: 52)
                    Text(kind.rawValue)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func promotionPreviewBoard() -> Board {
    var board = Board.standard()
    board[Square(row: 0, col: 3)] = nil
    board[Square(row: 0, col: 5)] = nil
    board[Square(row: 0, col: 6)] = nil
    board[Square(row: 1, col: 4)] = nil
    board[Square(row: 0, col: 4)] = Piece(kind: .pawn, color: .white)
    return board
}