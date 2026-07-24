import Foundation

/// The full structural model of a machine: every node and every transition,
/// derived directly from the live `ResolvedMachine`. This is the single source of
/// truth that the layout engine and both renderers consume.
public struct GraphModel: Sendable, Equatable {
    public let machineID: String
    public let rootID: String
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    /// Whether the layout engine should auto-lay-out this machine (the layered/Sugiyama flow with
    /// edge routing + disambiguation). When `false`, the renderer preserves a fixed arrangement —
    /// today's simple layout plus any `GraphStyle.nodeLayoutOverride` — instead of reflowing.
    /// Sourced from `StateMachine.useAutoLayoutForInspection` via the exported definition JSON.
    public let useAutoLayoutForInspection: Bool

    /// Fast lookup by node id.
    public let nodesByID: [String: GraphNode]
    /// Child node ids keyed by parent id, in definition order.
    public let childrenByID: [String: [String]]

    public init(machineID: String, rootID: String, nodes: [GraphNode], edges: [GraphEdge], useAutoLayoutForInspection: Bool = true) {
        self.machineID = machineID
        self.rootID = rootID
        self.nodes = nodes
        self.edges = edges
        self.useAutoLayoutForInspection = useAutoLayoutForInspection

        var byID: [String: GraphNode] = [:]
        byID.reserveCapacity(nodes.count)
        for node in nodes { byID[node.id] = node }
        self.nodesByID = byID

        var children: [String: [String]] = [:]
        for node in nodes where node.parentID != nil {
            children[node.parentID!, default: []].append(node.id)
        }
        // Keep children in definition order for stable layout.
        for (parent, ids) in children {
            children[parent] = ids.sorted { (byID[$0]?.order ?? 0) < (byID[$1]?.order ?? 0) }
        }
        self.childrenByID = children
    }

    public func node(_ id: String) -> GraphNode? { nodesByID[id] }
    public func children(of id: String) -> [String] { childrenByID[id] ?? [] }

    /// A stable signature of the *structure* (ids, hierarchy, transitions). Used to
    /// decide whether an expensive relayout is needed — it ignores live state.
    ///
    /// Order-independent: nodes and edges are folded in *sorted* so that two models with the
    /// same topology but a different array order (e.g. rebuilt from JSON, where dictionary
    /// iteration order isn't stable) hash equal — otherwise the renderer would needlessly
    /// rebuild on every update.
    public var structureHash: Int {
        var hasher = Hasher()
        hasher.combine(machineID)
        hasher.combine(useAutoLayoutForInspection)
        for node in nodes.sorted(by: { $0.id < $1.id }) {
            hasher.combine(node.id)
            hasher.combine(node.parentID)
            hasher.combine(node.order)
        }
        for edge in edges.map({ "\($0.from)\u{1}\($0.to)\u{1}\($0.label)" }).sorted() {
            hasher.combine(edge)
        }
        return hasher.finalize()
    }

    public static let empty = GraphModel(machineID: "", rootID: "", nodes: [], edges: [])
}
