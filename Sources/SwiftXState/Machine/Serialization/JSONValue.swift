
/// A JSON-compatible value for machine definition export.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    // TODO (when Hastings lands): add an `integer` case (matching FridayTheThirteenth's Int64/float
    // split, ideally Hastings' XSInteger) so big integers (> 2^53) survive the assign/inspection
    // round-trip. `.number(Double)` is lossy for large ints today; then drop `writeWholeFloatsAsIntegers`.
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// Serialize to compact, sorted-key JSON. Uses the dependency-free writer in
    /// `JSONValueCodec.swift` — no `Codable`, no reflection, no Foundation — so machine-definition
    /// export stays available to Embedded clients.
    public static func encode(_ value: JSONValue) throws -> String {
        value.serialized()
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
