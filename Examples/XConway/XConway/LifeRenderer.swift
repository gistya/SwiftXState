import SwiftUI

// MARK: - Performant Metal-backed Life grid (uses SwiftUI Canvas which is Metal accelerated under the hood on macOS)

public struct LifeGridCanvas: View {
    public let width: Int
    public let height: Int
    public let cells: [Bool]
    public let liveColor: Color
    public let onToggle: (Int, Int) -> Void

    public init(width: Int, height: Int, cells: [Bool], liveColor: Color = Color(red: 0.2, green: 0.92, blue: 0.35), onToggle: @escaping (Int, Int) -> Void) {
        self.width = max(8, width)
        self.height = max(8, height)
        self.cells = cells
        self.liveColor = liveColor
        self.onToggle = onToggle
    }

    public var body: some View {
        Canvas { graphicsContext, size in
            let cellW = size.width / CGFloat(width)
            let cellH = size.height / CGFloat(height)
            let cellSize = min(cellW, cellH)   // keep square cells even if view aspect differs slightly
            let offsetX = (size.width - cellSize * CGFloat(width)) / 2
            let offsetY = (size.height - cellSize * CGFloat(height)) / 2

            // Batch all live cells into a single Path for much lower overhead than one Path per cell.
            // This is the main win for high generation rates in Play mode.
            var livePath = Path()
            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * width + x
                    if cells[idx] {
                        let rect = CGRect(
                            x: offsetX + CGFloat(x) * cellSize,
                            y: offsetY + CGFloat(y) * cellSize,
                            width: cellSize,
                            height: cellSize
                        )
                        livePath.addRect(rect)
                    }
                }
            }
            if !livePath.isEmpty {
                graphicsContext.fill(livePath, with: .color(liveColor))
            }
        }
        .background(Color.black.opacity(0.92))
    }
}

// Interactive wrapper: GeometryReader gives us real pixel size for hit testing, plus border and gestures.
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

