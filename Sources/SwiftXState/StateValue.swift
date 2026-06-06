import Foundation

/// Represents the active state value of a state machine snapshot.
///
/// - Atomic states use a `String` (e.g. `"yellow"`).
/// - Compound/parallel states use a nested dictionary (e.g. `["red": "wait"]`).
public enum StateValue: Sendable, Equatable, Hashable, Codable {
    case atomic(String)
    case compound([String: StateValue])

    public init?(from value: Any) {
        if let string = value as? String {
            self = .atomic(string)
        } else if let dict = value as? [String: Any] {
            var compound: [String: StateValue] = [:]
            for (key, val) in dict {
                guard let stateValue = StateValue(from: val) else { return nil }
                compound[key] = stateValue
            }
            self = .compound(compound)
        } else {
            return nil
        }
    }

    /// Whether this state value is a subset of (or equal to) the given partial value.
    public func matches(_ partial: StateValue) -> Bool {
        switch (self, partial) {
        case let (.atomic(current), .atomic(target)):
            return current == target
        case let (.compound(current), .atomic(target)):
            return current.keys.contains(target)
        case let (.atomic(current), .compound(target)):
            return target.keys.contains(current)
        case let (.compound(current), .compound(target)):
            for (key, targetValue) in target {
                guard let currentValue = current[key] else { return false }
                if !currentValue.matches(targetValue) { return false }
            }
            return true
        }
    }

    /// Whether this state value matches a string path like `"red.wait"`.
    public func matches(_ path: String) -> Bool {
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return false }

        switch self {
        case let .atomic(current):
            if parts.count == 1 { return current == first }
            return false
        case let .compound(current):
            guard let child = current[first] else { return false }
            if parts.count == 1 { return true }
            return child.matches(parts.dropFirst().joined(separator: "."))
        }
    }

    public var description: String {
        switch self {
        case let .atomic(value):
            return value
        case let .compound(values):
            let parts = values.map { key, value in
                switch value {
                case let .atomic(v): return "\(key).\(v)"
                case .compound: return "\(key).\(value.description)"
                }
            }.sorted()
            return parts.joined(separator: ", ")
        }
    }
}