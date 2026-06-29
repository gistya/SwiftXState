/// The type of a state node.
public enum StateNodeType: Sendable {
    /// A leaf state with no children.
    case atomic
    /// A state with child states, one of which is active at a time.
    case compound
    /// A state whose child regions are all active simultaneously.
    case parallel
    /// A terminal state; entering it completes its parent (and can emit output).
    case final
    /// A pseudo-state that restores the parent's previously-active child on re-entry.
    case history
}
