#if SWIFTXSTATE_GRAPH_UI
import CoreGraphics

/// The result of laying out a `GraphModel`: an absolute frame (in logical
/// coordinates) for every node, plus the overall content bounds. Containers
/// (compound / parallel) get frames that fully enclose their descendants, which
/// is what produces the nested "statechart" look.
public struct GraphLayoutResult: Sendable, Equatable {
    public var frames: [String: CGRect]
    /// The bounding rectangle of every frame, used to center/fit the graph.
    public var bounds: CGRect
    /// Routed edges keyed by edge id. Empty when the machine opts out of auto-layout
    /// (`useAutoLayoutForInspection == false`), in which case the renderer falls back to its
    /// classic centre-to-centre curves.
    public var routes: [String: EdgeRoute]

    public init(frames: [String: CGRect], bounds: CGRect, routes: [String: EdgeRoute] = [:]) {
        self.frames = frames
        self.bounds = bounds
        self.routes = routes
    }

    public static let empty = GraphLayoutResult(frames: [:], bounds: .zero)

    public func frame(_ id: String) -> CGRect? { frames[id] }
    public func route(_ edgeID: String) -> EdgeRoute? { routes[edgeID] }
}
#endif
