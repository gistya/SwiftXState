import SwiftXState

/// How much of an actor's `context` a transport puts on the wire.
///
/// The default, ``full``, publishes the whole context with every snapshot — simple, and what the
/// Stately inspector expects. The other modes exist to stop a chatty actor from flooding a remote
/// API with data the consumer already has (``diff``) or never wanted (``selected`` / ``none``).
///
/// Note these solve *different* problems: ``diff`` removes what's **repetitive**, ``selected``
/// removes what's **irrelevant**. They can't be combined today — pick the one that matches your
/// bottleneck.
///
/// > Important: ``full`` is the default and a no-op, so stock Stately usage is unaffected. Choosing
/// > any other mode applies to **every** wire format — including
/// > ``InspectWireFormat/stately`` — and produces a context payload that stock
/// > `@statelyai/inspect` cannot fully reconstruct on its own (deltas ride in an extra
/// > `contextDelta` key it ignores). Use the reduced modes with your own inspector or transport.
public enum InspectContextPublishing: Sendable, Equatable {
    /// Publish the entire context on every snapshot. The default.
    case full

    /// Publish only what changed since this actor's last published snapshot, as a
    /// ``ContextDelta`` in `snapshot.contextDelta` (with `snapshot.context` left empty).
    ///
    /// Because diffs are stateful, a **keyframe** (a full context) is published for an actor's first
    /// snapshot, whenever the transport reconnects, and every `keyframeEvery` snapshots thereafter —
    /// so a consumer that joins late or drops a message re-syncs on its own. Pass `0` to disable
    /// periodic keyframes (first-snapshot and reconnect keyframes still happen).
    case diff(keyframeEvery: Int = 50)

    /// Publish only these top-level context keys, dropping the rest.
    case selected(Set<String>)

    /// Publish no context at all — state values, events, and tags still flow.
    case none
}
