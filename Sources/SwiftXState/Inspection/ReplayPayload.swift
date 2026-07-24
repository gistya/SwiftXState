
/// XState-style event with a separate JSON payload for replay and inspection.
public struct PayloadEvent: Eventable, Equatable {
    public let type: String
    public let payload: JSONValue?

    public init(_ type: String, payload: JSONValue? = nil) {
        self.type = type
        self.payload = payload
    }
}

/// Events that expose structured data beyond their `type` string for replay recording.
public protocol ReplayPayloadRepresentable: Eventable {
    var replayPayload: JSONValue? { get }
}

/// Decodes replayed events back into app-specific `Eventable` values.
public typealias ReplayEventDecoder = @Sendable (ReplayableEvent) -> (any Eventable)?

// Codable is declared out-of-line and guarded — see CodableConformances.swift for the policy.
#if !hasFeature(Embedded)
extension PayloadEvent: Codable {}
#endif
