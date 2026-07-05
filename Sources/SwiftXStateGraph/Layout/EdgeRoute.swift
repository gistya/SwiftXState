#if SWIFTXSTATE_GRAPH_UI
import CoreGraphics

/// A routed transition, produced by the auto-layout engine so the renderer can draw a ported,
/// lane-separated, along-the-line-labelled edge instead of a naive centre-to-centre curve. All
/// points are absolute logical coordinates. Only present when the machine opts into auto-layout;
/// self-loops are not routed here (the renderer draws those directly).
public struct EdgeRoute: Sendable, Equatable {
    public let edgeID: String
    /// Control polyline: `[startPort, control, endPort]` — a quadratic Bézier the renderer strokes.
    public var points: [CGPoint]
    /// Point on the curve where the label pill is anchored (staggered per lane so pills don't stack).
    public var labelAnchor: CGPoint
    /// Tangent angle at `labelAnchor` (radians), already flipped to keep the text upright.
    public var labelAngle: CGFloat
    /// This edge's index among the edges sharing its unordered node pair — feeds the renderer's
    /// dash/outline tie-break when two same-pair lanes hash to similar colours.
    public let laneIndex: Int
    /// How many edges share this edge's unordered node pair (lane count).
    public let laneCount: Int
    /// Estimated width of the label pill (0 when the edge has no label). Used to keep labels from
    /// overlapping and to grow the fit-to-view bounds so labels aren't clipped.
    public var labelWidth: CGFloat

    public init(edgeID: String, points: [CGPoint], labelAnchor: CGPoint, labelAngle: CGFloat, laneIndex: Int, laneCount: Int, labelWidth: CGFloat = 0) {
        self.edgeID = edgeID
        self.points = points
        self.labelAnchor = labelAnchor
        self.labelAngle = labelAngle
        self.laneIndex = laneIndex
        self.laneCount = laneCount
        self.labelWidth = labelWidth
    }
}
#endif
