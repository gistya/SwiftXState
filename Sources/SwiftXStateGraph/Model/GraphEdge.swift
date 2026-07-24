/// A directed transition between two nodes in the rendered graph.
public struct GraphEdge: Identifiable, Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: String
    /// The label drawn on the edge (event type, `after 200ms`, `done`, …).
    public let label: String
    public let kind: GraphEdgeKind
    /// Whether the transition carries a guard condition (rendered with a dashed style).
    public let isGuarded: Bool
    /// Whether the source and target are the same node (rendered as a self-loop).
    public var isSelfLoop: Bool { from == to }

    public init(
        id: String,
        from: String,
        to: String,
        label: String,
        kind: GraphEdgeKind,
        isGuarded: Bool
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.kind = kind
        self.isGuarded = isGuarded
    }

    /// A deterministic hue in `[0, 1)` derived from the event label (a process-stable FNV-1a hash —
    /// *not* `hashValue`, so it never shifts between runs or snapshot baselines). Both the 2D and 3D
    /// renderers colour a transition from this, so a line and its label always match. Edges with no
    /// label (always/onDone) fall back to a hue seeded by their kind.
    public var stableHue: Double {
        let seed = label.isEmpty ? "kind:\(kind)" : label
        var h: UInt64 = 1469598103934665603              // FNV-1a offset basis
        for byte in seed.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return Double(h % 3600) / 3600.0
    }
}
