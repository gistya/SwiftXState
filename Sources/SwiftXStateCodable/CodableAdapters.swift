import FridayTheCodable
import SwiftXState

// MARK: - The ContextPersistable seam, satisfied for free by Codable

public extension ContextPersistable where Self: Encodable {
    /// Projects an `Encodable` context into a ``JSONValue`` — so a `Codable` context satisfies
    /// ``ContextPersistable`` with no hand-written code.
    func persistedProjection() throws -> JSONValue {
        guard let bytes = try? FridayJSONEncoder.swiftXState.encode(self),
              let json = try? FridayJSONDecoder().decode(JSONValue.self, from: bytes)
        else { throw PersistenceError.contextEncodingFailed }
        return json
    }
}

public extension ContextPersistable where Self: Decodable {
    /// Rebuilds a `Decodable` context from a ``JSONValue``.
    static func materialized(from json: JSONValue) throws -> Self {
        guard let bytes = try? FridayJSONEncoder.swiftXState.encode(json),
              let value = try? FridayJSONDecoder().decode(Self.self, from: bytes)
        else { throw PersistenceError.contextDecodingFailed }
        return value
    }
}

// MARK: - Persisted snapshots

public extension PersistedSnapshot {
    /// Serialize a persisted snapshot to JSON bytes.
    func encodeJSON() throws -> [UInt8] {
        [UInt8](try FridayJSONEncoder.swiftXState.encode(self))
    }

    /// Rebuild a persisted snapshot from JSON bytes.
    static func decodeJSON(_ data: [UInt8]) throws -> PersistedSnapshot {
        try FridayJSONDecoder().decode(PersistedSnapshot.self, from: Array(data))
    }
}

// MARK: - Replay serialization

public extension ReplaySession {
    /// Serialize a recorded replay session to JSON bytes.
    func encodeJSON() throws -> [UInt8] {
        [UInt8](try FridayJSONEncoder.swiftXState.encode(self))
    }

    /// Rebuild a replay session from JSON bytes.
    static func decodeJSON(_ data: [UInt8]) throws -> ReplaySession {
        try FridayJSONDecoder().decode(ReplaySession.self, from: Array(data))
    }
}

// MARK: - Encodable ⇄ JSONValue bridges

public extension JSONValue {
    /// Convert any `Encodable` value into a ``JSONValue`` tree.
    static func fromEncodable<T: Encodable>(
        _ value: T,
        excludingTypeKey: Bool = false
    ) -> JSONValue? {
        guard let bytes = try? FridayJSONEncoder.swiftXState.encode(value),
              var json = try? FridayJSONDecoder().decode(JSONValue.self, from: bytes)
        else { return nil }
        if excludingTypeKey, case var .object(dict) = json {
            dict.removeValue(forKey: "type")
            json = dict.isEmpty ? .null : .object(dict)
        }
        if case .null = json { return nil }
        return json
    }

    /// Decode this ``JSONValue`` into a `Decodable` value.
    func decode<T: Decodable>(_ type: T.Type = T.self) -> T? {
        guard let bytes = try? FridayJSONEncoder.swiftXState.encode(self) else { return nil }
        return try? FridayJSONDecoder().decode(T.self, from: bytes)
    }
}

public extension ReplayPayloadRepresentable where Self: Encodable {
    /// An `Encodable` event carries its own replay payload for free.
    var replayPayload: JSONValue? {
        JSONValue.fromEncodable(self, excludingTypeKey: true)
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

// MARK: - Parameterized guard / action payloads

public extension GuardParamValues where Self: Codable {
    /// A `Codable` params type serializes itself into a ``ParamsBox`` for free.
    func encodeToBox() -> ParamsBox {
        guard let bytes = try? FridayJSONEncoder.swiftXState.encode(self),
              let json = try? FridayJSONDecoder().decode(JSONValue.self, from: bytes)
        else { return ParamsBox() }
        return ParamsBox(json: json)
    }

    static func decode(from box: ParamsBox?) -> Self? {
        guard let box, !box.isVoid else {
            return (Self.self == VoidParams.self) ? (VoidParams() as? Self) : nil
        }
        guard case let .json(json) = box.storage,
              let bytes = try? FridayJSONEncoder.swiftXState.encode(json),
              let decoded = try? FridayJSONDecoder().decode(Self.self, from: bytes)
        else { return nil }
        return decoded
    }
}

// MARK: - Codable-constrained persistence (the pre-2.0 signatures, preserved)

/// Creates a persisted snapshot from a `Codable` context — the signature SwiftXState 1.x shipped.
/// Encodes the context exactly as before, so persisted data stays byte-identical.
public func getPersistedSnapshot<Context: Codable & Sendable>(
    from snapshot: MachineSnapshot<Context>,
    children: [String: PersistedChildSnapshot] = [:]
) throws -> PersistedSnapshot {
    guard let contextBytes = try? FridayJSONEncoder.swiftXState.encode(snapshot.context) else {
        throw PersistenceError.contextEncodingFailed
    }
    return try getPersistedSnapshot(
        from: snapshot,
        contextBytes: [UInt8](contextBytes),
        children: children
    )
}

/// Restores a machine snapshot for a `Codable` context — the signature SwiftXState 1.x shipped.
public func restoreSnapshot<Context: Codable & Sendable>(
    machine: ResolvedMachine<Context>,
    persisted: PersistedSnapshot,
    context overrideContext: Context? = nil
) throws -> MachineSnapshot<Context> {
    let context: Context
    if let overrideContext {
        context = overrideContext
    } else if let decoded = try? FridayJSONDecoder().decode(Context.self, from: Array(persisted.context)) {
        context = decoded
    } else {
        throw PersistenceError.contextDecodingFailed
    }
    return try restoreSnapshot(machine: machine, persisted: persisted, decodedContext: context)
}
