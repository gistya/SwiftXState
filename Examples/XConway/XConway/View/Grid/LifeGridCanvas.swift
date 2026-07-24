import SwiftUI

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
