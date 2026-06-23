import Foundation

// MARK: - Params transport (runtime / wire)

/// Runtime parameter payload for parameterized guards and actions.
public struct ParamsBox: Sendable, Equatable {
    public enum Storage: Sendable, Equatable {
        case void
        case json(JSONValue)
    }

    public let storage: Storage

    public init(void: Void = ()) {
        storage = .void
    }

    public init(fields: [String: SendableValue]) {
        storage = .json(Self.jsonValue(from: fields))
    }

    public init(json: JSONValue) {
        storage = .json(json)
    }

    public var isVoid: Bool {
        switch storage {
        case .void:
            return true
        case .json(.null):
            return true
        case .json(.object(let object)) where object.isEmpty:
            return true
        default:
            return false
        }
    }

    static func jsonValue(from fields: [String: SendableValue]) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            object[key] = InspectJSONEncoder.encode(value)
        }
        return .object(object)
    }
}

extension JSONValue {
    static func fromAny(_ value: Any) -> JSONValue {
        if value is NSNull { return .null }
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .number(Double(int))
        case let int8 as Int8:
            return .number(Double(int8))
        case let int16 as Int16:
            return .number(Double(int16))
        case let int32 as Int32:
            return .number(Double(int32))
        case let int64 as Int64:
            return .number(Double(int64))
        case let uint as UInt:
            return .number(Double(uint))
        case let double as Double:
            return .number(double)
        case let float as Float:
            return .number(Double(float))
        case let array as [Any]:
            return .array(array.map(fromAny))
        case let object as [String: Any]:
            var mapped: [String: JSONValue] = [:]
            for (key, nested) in object.sorted(by: { $0.key < $1.key }) {
                mapped[key] = fromAny(nested)
            }
            return .object(mapped)
        default:
            return .null
        }
    }

    func codableData() throws -> Data {
        let text = try JSONValue.encode(self)
        guard let data = text.data(using: .utf8) else {
            throw MachineDefinitionError.encodingFailed
        }
        return data
    }
}

// MARK: - Typed param values

public protocol GuardParamValues: Sendable {
    func encodeToBox() -> ParamsBox
    static func decode(from box: ParamsBox?) -> Self?
}

public typealias ActionParamValues = GuardParamValues

/// Zero-parameter guard/action payloads.
public struct VoidParams: GuardParamValues, Sendable, Equatable, Codable {
    public init() {}

    public func encodeToBox() -> ParamsBox { ParamsBox() }

    public static func decode(from box: ParamsBox?) -> VoidParams? {
        guard box == nil || box?.isVoid == true else { return nil }
        return VoidParams()
    }
}

extension GuardParamValues where Self: Codable {
    public func encodeToBox() -> ParamsBox {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return ParamsBox()
        }
        return ParamsBox(json: JSONValue.fromAny(object))
    }

    public static func decode(from box: ParamsBox?) -> Self? {
        guard let box, !box.isVoid else {
            return (Self.self == VoidParams.self) ? (VoidParams() as? Self) : nil
        }
        guard case let .json(json) = box.storage,
              let data = try? json.codableData(),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        return decoded
    }
}

// MARK: - Guard / action specs

/// Compile-time guard identity for `setup().registerGuard(_:body:)`.
public protocol GuardSpec: Sendable {
    associatedtype Params: GuardParamValues = VoidParams
    static var name: String { get }
}

/// Compile-time action identity for `setup().registerAction(_:body:)`.
public protocol ActionSpec: Sendable {
    associatedtype Params: ActionParamValues = VoidParams
    static var name: String { get }
}

// MARK: - Guard references

extension GuardRef {
    /// Typed parameterized guard (Swift-native).
    public static func ref<G: GuardSpec>(
        _ spec: G.Type,
        params: G.Params
    ) -> GuardRef<Context> where Context: Sendable {
        let box = params.encodeToBox()
        if box.isVoid {
            return .named(G.name)
        }
        return .parameterized(G.name, box)
    }

    /// Typed guard without params.
    public static func ref<G: GuardSpec>(
        _ spec: G.Type
    ) -> GuardRef<Context> where Context: Sendable, G.Params == VoidParams {
        .named(G.name)
    }

    /// XState-style dynamic guard `{ type, params }`.
    public static func dynamic(
        _ name: String,
        params: [String: SendableValue]? = nil
    ) -> GuardRef<Context> where Context: Sendable {
        guard let params, !params.isEmpty else {
            return .named(name)
        }
        return .parameterized(name, ParamsBox(fields: params))
    }

    /// XState-style dynamic guard with JSON params.
    public static func dynamic(
        _ name: String,
        params: JSONValue
    ) -> GuardRef<Context> where Context: Sendable {
        let box = ParamsBox(json: params)
        if box.isVoid {
            return .named(name)
        }
        return .parameterized(name, box)
    }
}

/// Convenience free function for typed guards.
public func guardRef<Context: Sendable, G: GuardSpec>(
    _ spec: G.Type,
    params: G.Params
) -> GuardRef<Context> {
    .ref(spec, params: params)
}

public func guardRef<Context: Sendable, G: GuardSpec>(
    _ spec: G.Type
) -> GuardRef<Context> where G.Params == VoidParams {
    .ref(spec)
}

/// XState-style dynamic guard reference.
public func dynamicGuard<Context: Sendable>(
    _ name: String,
    params: [String: SendableValue]? = nil
) -> GuardRef<Context> {
    .dynamic(name, params: params)
}

// MARK: - Action references

extension ActionRef {
    public static func ref<A: ActionSpec>(
        _ spec: A.Type,
        params: A.Params
    ) -> ActionRef<Context> where Context: Sendable {
        let box = params.encodeToBox()
        if box.isVoid {
            return .named(A.name)
        }
        return .parameterized(A.name, box)
    }

    public static func ref<A: ActionSpec>(
        _ spec: A.Type
    ) -> ActionRef<Context> where Context: Sendable, A.Params == VoidParams {
        .named(A.name)
    }

    public static func dynamic(
        _ name: String,
        params: [String: SendableValue]? = nil
    ) -> ActionRef<Context> where Context: Sendable {
        guard let params, !params.isEmpty else {
            return .named(name)
        }
        return .parameterized(name, ParamsBox(fields: params))
    }

    public static func dynamic(
        _ name: String,
        params: JSONValue
    ) -> ActionRef<Context> where Context: Sendable {
        let box = ParamsBox(json: params)
        if box.isVoid {
            return .named(name)
        }
        return .parameterized(name, box)
    }
}

/// A reference to a named action with typed, bound parameters — the action counterpart of
/// `guardRef`. Register the spec with `setup().registerAction(_:_:)`; the `params` are serialized
/// into the exported definition JSON.
public func actionRef<Context: Sendable, A: ActionSpec>(
    _ spec: A.Type,
    params: A.Params
) -> ActionRef<Context> {
    .ref(spec, params: params)
}

public func actionRef<Context: Sendable, A: ActionSpec>(
    _ spec: A.Type
) -> ActionRef<Context> where A.Params == VoidParams {
    .ref(spec)
}

public func dynamicAction<Context: Sendable>(
    _ name: String,
    params: [String: SendableValue]? = nil
) -> ActionRef<Context> {
    .dynamic(name, params: params)
}

// MARK: - Implementation registration helpers

func wrapLegacyGuards<Context: Sendable>(
    _ guards: [String: @Sendable (ActionArgs<Context>) -> Bool]
) -> [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Bool] {
    guards.mapValues { handler in
        { args, _ in handler(args) }
    }
}

func wrapLegacyActions<Context: Sendable>(
    _ actions: [String: @Sendable (ActionArgs<Context>) -> Void]
) -> [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Void] {
    actions.mapValues { handler in
        { args, _ in handler(args) }
    }
}

func installGuard<Context: Sendable, G: GuardSpec>(
    _ spec: G.Type,
    body: @escaping @Sendable (ActionArgs<Context>, G.Params) -> Bool,
    into guards: inout [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Bool]
) {
    let name = G.name
    guards[name] = { args, box in
        guard let params = G.Params.decode(from: box) else { return false }
        return body(args, params)
    }
}

func installAction<Context: Sendable, A: ActionSpec>(
    _ spec: A.Type,
    body: @escaping @Sendable (ActionArgs<Context>, A.Params) -> Void,
    into actions: inout [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Void]
) {
    let name = A.name
    actions[name] = { args, box in
        guard let params = A.Params.decode(from: box) else { return }
        body(args, params)
    }
}

func serializeParameterizedReference(name: String, params: ParamsBox) -> JSONValue {
    guard !params.isVoid else {
        return .string(name)
    }
    guard case let .json(json) = params.storage else {
        return .object([
            "type": .string(name),
            "params": .null,
        ])
    }
    return .object([
        "type": .string(name),
        "params": json,
    ])
}