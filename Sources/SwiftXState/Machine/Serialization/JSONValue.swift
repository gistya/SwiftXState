import FridayTheCodable

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

    public static func encode(_ value: JSONValue) throws -> String {
        try FridayJSONEncoder.swiftXStateSorted.encodeString(value)
    }
}

extension FridayJSONEncoder {
    /// SwiftXState's standard JSON encoder. `writeWholeFloatsAsIntegers` mirrors the old Foundation
    /// output (a whole `Double` like `5.0` is written `5`) and — crucially — lets a
    /// `JSONValue.number(Double)` round-trip back into an `Int`-typed `Codable`, since
    /// FridayTheThirteenth decodes integers strictly (a JSON float won't decode into `Int`).
    static var swiftXState: FridayJSONEncoder {
        FridayJSONEncoder(outputFormatting: JSONSerializeOptions(writeWholeFloatsAsIntegers: true))
    }

    /// As ``swiftXState`` but with sorted keys, for deterministic machine-definition output.
    static var swiftXStateSorted: FridayJSONEncoder {
        FridayJSONEncoder(outputFormatting: JSONSerializeOptions(sortedKeys: true, writeWholeFloatsAsIntegers: true))
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
