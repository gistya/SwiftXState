import Foundation

/// The arguments handed to a transition `action` handler — XState v6's handler `args`. Carries the
/// current `context` and the `event` that triggered the transition.
public struct XTransitionArgs<Context: Sendable, EventID: EventIdentifying>: Sendable {
    public let context: Context
    public let event: any Eventable
}

/// The effect channel handed to a transition `action` handler — XState v6's `enq`. Effects are
/// **collected, not performed inline**, then run by the engine *after* the context patch. So
/// `raise` respects run-to-completion: the raised event is queued and processed after the current
/// macrostep, never re-entering it.
public final class Enqueue<Context: Sendable, EventID: EventIdentifying>: @unchecked Sendable {
    public let context: Context
    public let event: any Eventable

    /// The effects gathered during the handler, lowered to engine action refs.
    var collected: [ActionRef<Context>] = []

    init(context: Context, event: any Eventable) {
        self.context = context
        self.event = event
    }

    /// Raise an internal event — queued, processed after the current macrostep (RTC-safe).
    public func raise(_ id: EventID) {
        collected.append(SwiftXState.raise(id.event))
    }

    /// Send an event to a child actor by id.
    public func sendTo(_ childId: String, _ id: EventID) {
        collected.append(.sendTo(SendToAction(target: .fixed(childId), event: .fixed(id.event))))
    }

    /// Emit an event to `on(_:)` listeners.
    public func emit(_ event: EmittedEvent) {
        collected.append(SwiftXState.emit(event))
    }
}
