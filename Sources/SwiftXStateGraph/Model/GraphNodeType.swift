/// The kind of a state node, mirrored from the core `StateNodeType` so the
/// renderer can stay independent of the core's internal enum naming.
public enum GraphNodeType: Sendable, Equatable {
    case atomic
    case compound
    case parallel
    case final
    case history

    /// Whether this node contains child states (and is therefore drawn as a region/container).
    public var isContainer: Bool {
        self == .compound || self == .parallel
    }
}
