import SwiftUI

struct ChessPieceView: View {
    let piece: Piece
    var size: CGFloat = 44

    private var assetName: String {
        "\(piece.color.rawValue)_\(piece.kind.rawValue)"
    }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.22))
                .frame(width: size * 0.58, height: size * 0.12)
                .offset(y: size * 0.14)
                .blur(radius: 2)

            Image(assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.7, height: size * 0.7)
        }
        .frame(width: size, height: size)
    }
}

struct PromotionPicker: View {
    let color: PieceColor
    let onSelect: (PieceKind) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PieceKind.promotionChoices, id: \.self) { kind in
                Button {
                    onSelect(kind)
                } label: {
                    ChessPieceView(piece: Piece(kind: kind, color: color), size: 40)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThinMaterial)
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.08))
        )
    }
}
