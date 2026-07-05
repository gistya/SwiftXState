#if SWIFTXSTATE_GRAPH_UI
import SwiftUI

/// Maps between screen (viewport) coordinates and the graph's logical coordinate
/// space, given the current zoom/pan. The transform anchors the content's bounds
/// center at the viewport center plus the pan offset:
///
///     screen = (logical - center) * zoom + viewport/2 + pan
struct GraphTransform {
    var zoom: CGFloat
    var pan: CGSize
    var viewport: CGSize
    var center: CGPoint

    func screen(from logical: CGPoint) -> CGPoint {
        CGPoint(
            x: (logical.x - center.x) * zoom + viewport.width / 2 + pan.width,
            y: (logical.y - center.y) * zoom + viewport.height / 2 + pan.height
        )
    }

    func logical(from screen: CGPoint) -> CGPoint {
        CGPoint(
            x: (screen.x - viewport.width / 2 - pan.width) / zoom + center.x,
            y: (screen.y - viewport.height / 2 - pan.height) / zoom + center.y
        )
    }
}
#endif
