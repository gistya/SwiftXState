
/// An event that can be sent to a state machine actor. Conform a Swift enum for a typed event
/// union, or use the built-in `Event` for string events. `type` is the discriminator transitions
/// key on (`on: ["TYPE": …]`).
public protocol Eventable: Sendable, Equatable {
    /// The event's discriminator string (XState's `event.type`).
    var type: String { get }

    /// Payload recorded when this event is captured for replay or shown in the inspector.
    ///
    /// Defaults to `nil`; override on events that carry data. Declared here rather than discovered
    /// by casting to ``ReplayPayloadRepresentable``, because Embedded Swift permits `as?` to a
    /// *concrete* type but not to an existential (`as? any P`). A defaulted requirement is portable
    /// and puts the capability on the protocol instead of leaving it to be found at runtime.
    var replayPayload: JSONValue? { get }
}

public extension Eventable {
    /// Default: no replay payload.
    var replayPayload: JSONValue? { nil }
}

/// A simple string-backed event, matching XState's `{ type: 'EVENT_NAME' }` pattern.
public struct Event: Eventable, Hashable {
    public let type: String

    @inlinable
    public init(_ type: String) {
        self.type = type
    }
}

extension String: Eventable {
    public var type: String { self }
}

/// Wildcard event descriptor matching any event type.
public let wildcardEventDescriptor = "*"

/// Internal init event sent when an actor starts.
public enum SystemEvent: String, Eventable {
    case `init` = "xstate.init"
    case stop = "xstate.stop"

    public var type: String { rawValue }
}
