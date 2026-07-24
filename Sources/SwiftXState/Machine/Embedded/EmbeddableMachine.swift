// MARK: - Type-erased session

/// A running machine, erased over its concrete `Context`, so the engine can hold a
/// heterogeneous registry of them. Class-bound (reference existential) so it is
/// trivially fine under Embedded Swift.
///
/// Intended for use with Embedded Swift with WASM.
protocol EmbeddableMachine: AnyObject {
    /// Current top-level state value, rendered as a string (e.g. `"red.walk"`).
    var stateName: String { get }
    /// Whether the machine has reached a top-level final state.
    var isDone: Bool { get }
    /// The current context, projected to JSON for the UI (hand-written per machine —
    /// no reflection).
    var contextJSON: JSONValue { get }
    /// Every event this machine understands, in display order.
    var eventNames: [String] { get }
    /// Whether sending `event` right now would cause a transition (honors guards).
    func canSend(_ event: String) -> Bool
    /// Re-create the initial snapshot.
    func reset()
    /// Advance the machine by one event.
    func send(_ event: String)
}
