/// A node in the rendered graph. This is a flattened, value-type projection of a
/// `StateNode` from the live machine — everything the layout engine and renderers
/// need, with no reference back into the core types.
public struct GraphNode: Identifiable, Sendable, Equatable {
    /// Globally unique id (the core node id, e.g. `"chess.game.playing"`).
    public let id: String
    /// Display label (the local state key, or the machine id for the root).
    public let label: String
    /// Dotted path relative to the machine root (e.g. `"game.playing"`).
    /// This is what `StateValue.matches(_:)` expects, so it drives highlighting.
    public let relativePath: String
    /// Parent node id, or `nil` for the root.
    public let parentID: String?
    public let type: GraphNodeType
    /// Definition order among siblings (used for stable layout).
    public let order: Int
    /// Whether this node is its parent's `initial` child.
    public let isInitialChild: Bool
    /// Optional human description supplied in the machine config.
    public let nodeDescription: String?

    public init(
        id: String,
        label: String,
        relativePath: String,
        parentID: String?,
        type: GraphNodeType,
        order: Int,
        isInitialChild: Bool,
        nodeDescription: String?
    ) {
        self.id = id
        self.label = label
        self.relativePath = relativePath
        self.parentID = parentID
        self.type = type
        self.order = order
        self.isInitialChild = isInitialChild
        self.nodeDescription = nodeDescription
    }
}
