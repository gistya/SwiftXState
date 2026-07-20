/// A structural difference between two ``JSONValue`` trees — the payload behind inspection's
/// **Diff Mode**, which publishes only what changed in an actor's context instead of the whole thing.
///
/// This is deliberately *not* RFC 7386 JSON Merge Patch: merge-patch uses `null` to mean "delete",
/// which is ambiguous here because ``JSONValue`` has a real ``JSONValue/null`` case (a context field
/// genuinely set to null is not a deletion). ``removed`` is an explicit case instead, so a delta is
/// lossless.
///
/// It is pure tree-walking — no `Codable`, no reflection — so it works everywhere the core does,
/// including Embedded Swift, where saving bandwidth matters most.
public indirect enum ContextDelta: Sendable, Equatable {
    /// The value is identical; nothing to send.
    case unchanged
    /// Replace wholesale — a keyframe, a type change, or a non-object value.
    case replace(JSONValue)
    /// An object changed per-key. Only changed keys appear.
    case merge([String: ContextDelta])
    /// The key was present before and is absent now.
    case removed
}

public extension ContextDelta {
    /// Computes the delta that turns `old` into `new`.
    ///
    /// Objects recurse key-by-key so only the changed leaves travel. Everything else (arrays,
    /// scalars, or a change of shape) is a wholesale `replace` — arrays are treated atomically,
    /// which keeps the delta small and unambiguous for the common "context is a struct" case.
    static func between(_ old: JSONValue, _ new: JSONValue) -> ContextDelta {
        if old == new { return .unchanged }
        guard case let .object(oldFields) = old, case let .object(newFields) = new else {
            return .replace(new)
        }
        var fields: [String: ContextDelta] = [:]
        for (key, newValue) in newFields {
            if let oldValue = oldFields[key] {
                let delta = between(oldValue, newValue)
                if delta != .unchanged { fields[key] = delta }
            } else {
                fields[key] = .replace(newValue)
            }
        }
        for key in oldFields.keys where newFields[key] == nil {
            fields[key] = .removed
        }
        return fields.isEmpty ? .unchanged : .merge(fields)
    }

    /// Rebuilds the new value by applying this delta to `base`. `ContextDelta.between(a, b).applied(to: a) == b`.
    func applied(to base: JSONValue) -> JSONValue {
        switch self {
        case .unchanged:
            return base
        case let .replace(value):
            return value
        case .removed:
            // A removal is enacted by the enclosing `.merge`; standalone it means "gone".
            return .null
        case let .merge(fields):
            var result: [String: JSONValue] = {
                if case let .object(existing) = base { return existing }
                return [:]
            }()
            for (key, delta) in fields {
                if case .removed = delta {
                    result.removeValue(forKey: key)
                } else {
                    result[key] = delta.applied(to: result[key] ?? .null)
                }
            }
            return .object(result)
        }
    }

    /// The wire form: a tagged object so a consumer can reconstruct without guessing.
    ///
    /// - `{"op":"replace","value":…}`
    /// - `{"op":"merge","fields":{key: <delta>, …}}`
    /// - `{"op":"remove"}`
    /// - `{"op":"unchanged"}`
    func jsonValue() -> JSONValue {
        switch self {
        case .unchanged:
            return .object(["op": .string("unchanged")])
        case let .replace(value):
            return .object(["op": .string("replace"), "value": value])
        case .removed:
            return .object(["op": .string("remove")])
        case let .merge(fields):
            var encoded: [String: JSONValue] = [:]
            for (key, delta) in fields { encoded[key] = delta.jsonValue() }
            return .object(["op": .string("merge"), "fields": .object(encoded)])
        }
    }

    /// Rebuilds a delta from its ``jsonValue()`` wire form.
    static func fromJSON(_ json: JSONValue) -> ContextDelta? {
        guard case let .object(object) = json,
              case let .string(op)? = object["op"] else { return nil }
        switch op {
        case "unchanged": return .unchanged
        case "remove": return .removed
        case "replace":
            guard let value = object["value"] else { return nil }
            return .replace(value)
        case "merge":
            guard case let .object(fields)? = object["fields"] else { return nil }
            var result: [String: ContextDelta] = [:]
            for (key, encoded) in fields {
                guard let delta = fromJSON(encoded) else { return nil }
                result[key] = delta
            }
            return .merge(result)
        default:
            return nil
        }
    }
}
