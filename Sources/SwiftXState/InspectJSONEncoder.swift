import Foundation

enum InspectJSONEncoder {
    static func encode<Context>(_ context: Context) -> JSONValue {
        if context is EmptyContext {
            return .object([:])
        }
        return mirrorEncode(context) ?? .object([:])
    }

    static func encode(_ value: SendableValue) -> JSONValue {
        if let string = value.get(String.self) {
            return .string(string)
        }
        if let int = value.get(Int.self) {
            return .number(Double(int))
        }
        if let double = value.get(Double.self) {
            return .number(double)
        }
        if let bool = value.get(Bool.self) {
            return .bool(bool)
        }
        return mirrorEncode(value.boxedForInspection) ?? .null
    }

    static func encodeChildren(_ children: [String: ChildActorSnapshot]) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for (key, child) in children.sorted(by: { $0.key < $1.key }) {
            var childObject: [String: JSONValue] = [
                "id": .string(child.id),
                "status": .string(snapshotStatus(child.status)),
            ]
            if let value = child.value {
                childObject["value"] = .string(value)
            }
            if let error = child.error {
                childObject["error"] = .string(error)
            }
            object[key] = .object(childObject)
        }
        return .object(object)
    }

    private static func snapshotStatus(_ status: SnapshotStatus) -> String {
        switch status {
        case .active: return "active"
        case .done: return "done"
        case .error: return "error"
        case .stopped: return "stopped"
        }
    }

    private static func mirrorEncode(_ value: Any) -> JSONValue? {
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
        default:
            break
        }

        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let child = mirror.children.first else { return .null }
            return mirrorEncode(child.value)
        case .collection, .set:
            let values = mirror.children.compactMap { mirrorEncode($0.value) }
            return .array(values)
        case .dictionary:
            var object: [String: JSONValue] = [:]
            for child in mirror.children {
                let pair = Mirror(reflecting: child.value)
                guard pair.children.count == 2 else { continue }
                let parts = Array(pair.children)
                guard
                    let key = parts[0].value as? String,
                    let encoded = mirrorEncode(parts[1].value)
                else { continue }
                object[key] = encoded
            }
            return .object(object)
        case .struct, .class:
            var object: [String: JSONValue] = [:]
            for child in mirror.children {
                guard let label = child.label, let encoded = mirrorEncode(child.value) else { continue }
                object[label] = encoded
            }
            return .object(object)
        case .enum:
            if let raw = mirror.children.first?.value as? String {
                return .string(raw)
            }
            if let display = mirror.children.first?.label {
                return .string(display)
            }
            return .string(String(describing: value))
        default:
            return .string(String(describing: value))
        }
    }
}
