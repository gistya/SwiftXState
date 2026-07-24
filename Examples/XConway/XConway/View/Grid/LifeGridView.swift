import SwiftUI

/// Interactive wrapper: GeometryReader gives us real pixel size for hit testing, plus border and gestures.
public struct LifeGridView: View {
    public let context: LifeContext
    public let onToggle: (Int, Int) -> Void

    @State private var lastCell: (Int, Int)? = nil

    public init(context: LifeContext, onToggle: @escaping (Int, Int) -> Void) {
        self.context = context
        self.onToggle = onToggle
    }

    public var body: some View {
        GeometryReader { proxy in
            let viewSize = proxy.size
            LifeGridCanvas(
                width: context.width,
                height: context.height,
                cells: context.cells,
                onToggle: onToggle
            )
            .contentShape(Rectangle())
            .gesture(
                TapGesture()
                    .onEnded { _ in lastCell = nil }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let cell = cellAt(location: value.location, viewSize: viewSize) {
                            if lastCell?.0 != cell.0 || lastCell?.1 != cell.1 {
                                lastCell = cell
                                onToggle(cell.0, cell.1)
                            }
                        }
                    }
                    .onEnded { _ in lastCell = nil }
            )
        }
        .aspectRatio(CGFloat(context.width) / CGFloat(context.height), contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func cellAt(location: CGPoint, viewSize: CGSize) -> (Int, Int)? {
        guard context.width > 0, context.height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let cellW = viewSize.width / CGFloat(context.width)
        let cellH = viewSize.height / CGFloat(context.height)
        let cellSize = min(cellW, cellH)
        let offsetX = (viewSize.width - cellSize * CGFloat(context.width)) / 2
        let offsetY = (viewSize.height - cellSize * CGFloat(context.height)) / 2
        let lx = location.x - offsetX
        let ly = location.y - offsetY
        if lx < 0 || ly < 0 || lx > cellSize * CGFloat(context.width) || ly > cellSize * CGFloat(context.height) { return nil }
        let cx = Int(floor(lx / cellSize))
        let cy = Int(floor(ly / cellSize))
        return (max(0, min(context.width - 1, cx)), max(0, min(context.height - 1, cy)))
    }
}
