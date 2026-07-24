/// The semantic category of a transition, so the renderer can style each kind.
public enum GraphEdgeKind: Sendable, Equatable {
    /// A normal event-driven transition (`on: [...]`).
    case event
    /// An eventless / "always" transition.
    case always
    /// A delayed (`after:`) transition.
    case after
    /// A transition taken when a compound/parallel region completes (`onDone`).
    case onDone
    /// An invoked-actor done/error transition.
    case invoked
}
