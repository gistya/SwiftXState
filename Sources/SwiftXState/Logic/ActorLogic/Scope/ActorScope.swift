/// Handed to `ActorLogic.run` so a background driver (callback / task / observable child) can drive
/// its host actor: push snapshots (`update`), consume incoming events (`receive`), and produce
/// outbound effects (`sendToParent` / `emit`) — the latter routed through the host's ordered effect
/// chain. Mirrors XState v6's `CallbackLogicFunction` scope (`sendBack` / `receive` / `emit`).
public struct ActorScope<Snapshot: Sendable>: Sendable {
    /// This actor's id — so a logic can build child-targeted events (e.g. `SnapshotActorEvent`).
    public let actorId: String
    public let input: SendableValue?
    /// Push a new snapshot (dropped once the logic is no longer `.active`).
    public let update: @Sendable (Snapshot) async -> Void
    /// Register a handler for events sent to this actor.
    public let receive: @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void
    /// Send an event up to the parent (ordered).
    public let sendToParent: @Sendable (any Eventable) -> Void
    /// Notify emit listeners.
    public let emit: @Sendable (EmittedEvent) -> Void
    /// Mark the child done with an optional output — delivers a `DoneActorEvent` to the parent on the
    /// SAME ordered chain as `sendToParent` (so a just-sent event lands first) and sets `.done`.
    public let complete: @Sendable (SendableValue?) -> Void
    /// Mark the child errored — delivers an `ErrorActorEvent` (ordered) and sets `.error`.
    public let fail: @Sendable (String) -> Void
}
