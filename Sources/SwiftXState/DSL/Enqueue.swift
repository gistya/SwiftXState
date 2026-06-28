import Foundation

/// The engine event a typed `EventID` lowers to — an `Eventable` whose `type` is the id's
/// discriminant `name` (so the engine routes on it) while the whole `id` value rides along, so a
/// payload-carrying case (`Event.increment(by: 5)`) survives a `send` and can be read back, typed,
/// in a handler via `XTransitionArgs.event`.
///
/// Note: only *directly sent* events carry their payload. Internally `raise`d / `sendTo` events go
/// through the engine's string-`Event` channel and keep only the discriminant.
public struct TypedEvent<EventID: EventIdentifying>: Eventable {
    public let id: EventID
    public var type: String { id.name }
    public init(_ id: EventID) { self.id = id }
}

/// The arguments handed to a transition `action` handler — XState v6's handler `args`. Carries the
/// current `context` and the typed `event` that triggered the transition (`nil` for the initial /
/// system events, or events that arrived without a typed payload, e.g. via `raise`).
public struct XTransitionArgs<Context: Sendable, EventID: EventIdentifying>: Sendable {
    public let context: Context
    public let event: EventID?

    public init(context: Context, event: EventID?) {
        self.context = context
        self.event = event
    }
}

/// The effect channel handed to a transition `action` handler — XState v6's `enq`. Effects are
/// **collected, not performed inline**, then run by the engine *after* the context patch. So
/// `raise` respects run-to-completion: the raised event is queued and processed after the current
/// macrostep, never re-entering it.
public final class Enqueue<Context: Sendable, EventID: EventIdentifying>: @unchecked Sendable {
    public let context: Context
    public let event: EventID?

    /// The effects gathered during the handler, lowered to engine action refs.
    var collected: [ActionRef<Context>] = []

    init(context: Context, event: EventID?) {
        self.context = context
        self.event = event
    }

    /// Raise an internal event — queued, processed after the current macrostep (RTC-safe). The
    /// engine's raise channel is string-keyed, so only the discriminant travels (no payload).
    public func raise(_ id: EventID) {
        collected.append(SwiftXState.raise(Event(id.name)))
    }

    /// Send an event to a child actor by id (discriminant only — no payload, per the engine's
    /// string-`Event` sendTo channel).
    public func sendTo(_ childId: String, _ id: EventID) {
        collected.append(.sendTo(SendToAction(target: .fixed(childId), event: .fixed(Event(id.name)))))
    }

    /// Emit an event to `on(_:)` listeners.
    public func emit(_ event: EmittedEvent) {
        collected.append(SwiftXState.emit(event))
    }
}
