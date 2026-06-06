#if SWIFTXSTATE_INSPECTOR_UI
import Foundation
import SwiftXState

/// The display category of a `JSONValue`, used to drive coloring and disclosure.
public enum JSONKind: Sendable {
    case object, array, string, number, bool, null
}

public extension JSONValue {
    var kind: JSONKind {
        switch self {
        case .object: return .object
        case .array: return .array
        case .string: return .string
        case .number: return .number
        case .bool: return .bool
        case .null: return .null
        }
    }

    /// Whether this node can be expanded (a non-empty object or array).
    var isExpandable: Bool {
        switch self {
        case let .object(o): return !o.isEmpty
        case let .array(a): return !a.isEmpty
        default: return false
        }
    }

    /// Child rows for the tree. Objects yield sorted `(key, value)`; arrays yield
    /// `(index, value)` in order. Scalars yield nothing.
    func treeChildren() -> [(key: String, value: JSONValue)] {
        switch self {
        case let .object(o):
            return o.keys.sorted().map { ($0, o[$0]!) }
        case let .array(a):
            return a.enumerated().map { (String($0.offset), $0.element) }
        default:
            return []
        }
    }

    /// Scalar text for a leaf value (quoted strings, formatted numbers, `null`).
    var scalarText: String {
        switch self {
        case let .string(s): return "\"\(s)\""
        case let .number(n): return JSONValue.formatNumber(n)
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        case .object, .array: return ""
        }
    }

    /// Short summary used when a collection is collapsed, e.g. `Array(9)` or a preview
    /// of the first object keys like `{value: Object, context: Object…}`.
    func collapsedSummary(maxKeys: Int = 3) -> String {
        switch self {
        case let .array(a):
            return "Array(\(a.count))"
        case let .object(o):
            if o.isEmpty { return "{}" }
            let keys = o.keys.sorted()
            let shown = keys.prefix(maxKeys).map { "\($0): \(o[$0]!.typeName)" }
            let suffix = keys.count > maxKeys ? "…" : ""
            return "{" + shown.joined(separator: ", ") + suffix + "}"
        default:
            return scalarText
        }
    }

    /// The bare type name shown when a collection is expanded, e.g. `Object`, `Array(9)`.
    var typeName: String {
        switch self {
        case .object: return "Object"
        case let .array(a): return "Array(\(a.count))"
        case .string: return "String"
        case .number: return "Number"
        case .bool: return "Bool"
        case .null: return "null"
        }
    }

    static func formatNumber(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    }
}
#endif
