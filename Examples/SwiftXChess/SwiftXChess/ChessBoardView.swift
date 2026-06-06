import SwiftUI

struct ChessBoardView: View {
    let board: Board
    let selected: Square?
    let pendingPromotion: PendingPromotion?
    let promotionColor: PieceColor
    let isInteractive: Bool
    let onTap: (Int, Int) -> Void
    let onPromote: (PieceKind) -> Void

    /// Edge length of a single square. Defaults to 56 (the macOS layout); iPad layouts pass a
    /// computed value so the board fits the available space.
    var tileSize: CGFloat = 56
    private let files = ["a", "b", "c", "d", "e", "f", "g", "h"]

    var body: some View {
        VStack(spacing: 0) {
            ForEach((0..<Board.size).reversed(), id: \.self) { row in
                HStack(spacing: 0) {
                    Text("\(row + 1)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    ForEach(0..<Board.size, id: \.self) { col in
                        tile(row: row, col: col)
                    }
                }
            }

            HStack(spacing: 0) {
                Text("")
                    .frame(width: 18)
                ForEach(files, id: \.self) { file in
                    Text(file)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: tileSize)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.36, green: 0.28, blue: 0.20),
                            Color(red: 0.28, green: 0.22, blue: 0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        )
        .overlay {
            if let pendingPromotion {
                promotionOverlay(for: pendingPromotion)
            }
        }
    }

    @ViewBuilder
    private func tile(row: Int, col: Int) -> some View {
        let square = Square(row: row, col: col)
        let isLight = !(row + col).isMultiple(of: 2)
        let isSelected = selected == square
        let isPromotionTarget = pendingPromotion?.to == square

        Button {
            guard isInteractive, pendingPromotion == nil else { return }
            onTap(row, col)
        } label: {
            ZStack {
                Rectangle()
                    .fill(tileColor(light: isLight, selected: isSelected, promotionTarget: isPromotionTarget))

                if isSelected {
                    Rectangle()
                        .strokeBorder(Color.yellow.opacity(0.9), lineWidth: 2)
                }

                if let piece = board[square] {
                    ChessPieceView(piece: piece, size: tileSize * 1.1)
                }
            }
            .frame(width: tileSize, height: tileSize)
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive || pendingPromotion != nil)
    }

    @ViewBuilder
    private func promotionOverlay(for pending: PendingPromotion) -> some View {
        GeometryReader { geometry in
            let boardOriginX: CGFloat = 18
            let boardOriginY: CGFloat = 10
            let x = boardOriginX + CGFloat(pending.to.col) * tileSize + tileSize / 2
            let rowFromBottom = pending.to.row
            let y = boardOriginY + CGFloat(Board.size - 1 - rowFromBottom) * tileSize

            PromotionPicker(color: promotionColor, onSelect: onPromote)
                .position(
                    x: x,
                    y: promotionColor == .white
                        ? max(y - tileSize * 0.9, 36)
                        : min(y + tileSize * 1.6, geometry.size.height - 36)
                )
        }
    }

    private func tileColor(light: Bool, selected: Bool, promotionTarget: Bool) -> Color {
        if promotionTarget {
            return Color.blue.opacity(0.35)
        }
        if selected {
            return Color.yellow.opacity(0.55)
        }
        return light
            ? Color(red: 1.0, green: 1.0, blue: 1.0)
            : Color(red: 0.6, green: 0.6, blue: 0.6)
    }
}
