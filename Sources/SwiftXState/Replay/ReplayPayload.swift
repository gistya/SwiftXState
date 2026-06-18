import Foundation

/// XState-style event with a separate JSON payload for replay and inspection.
public struct PayloadEvent: Eventable, Equatable, Codable {
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

extension ReplayPayloadRepresentable where Self: Encodable {
    public var replayPayload: JSONValue? {
        JSONValue.fromEncodable(self, excludingTypeKey: true)
    }
}

/// Decodes replayed events back into app-specific `Eventable` values.
public typealias ReplayEventDecoder = @Sendable (ReplayableEvent) -> (any Eventable)?

public extension JSONValue {
    static func fromEncodable<T: Encodable>(
        _ value: T,
        excludingTypeKey: Bool = false
    ) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value),
              var json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        if excludingTypeKey, case var .object(dict) = json {
            dict.removeValue(forKey: "type")
            json = dict.isEmpty ? .null : .object(dict)
        }
        if case .null = json { return nil }
        return json
    }

    func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Reconstructs a `Decodable` event from a recorded type + payload pair.
public func replayDecodeEvent<E: Eventable & Decodable>(
    type: String,
    payload: JSONValue?,
    as _: E.Type = E.self,
    expectedType: String? = nil
) -> E? {
    if let expectedType, type != expectedType { return nil }
    if let payload {
        var object: [String: JSONValue] = ["type": .string(type)]
        if case let .object(fields) = payload {
            for (key, value) in fields where key != "type" {
                object[key] = value
            }
        } else {
            object["payload"] = payload
        }
        return JSONValue.object(object).decode(E.self)
    }
    return JSONValue.object(["type": .string(type)]).decode(E.self)
}