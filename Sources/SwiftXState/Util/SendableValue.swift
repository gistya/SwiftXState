/// A type-erased sendable value for context properties.
public struct SendableValue: @unchecked Sendable, Equatable {
    private let box: any Sendable & Equatable

    public init<T: Sendable & Equatable>(_ value: T) {
        self.box = value
    }

    public func get<T: Sendable & Equatable>(_ type: T.Type = T.self) -> T? {
        box as? T
    }

    public static func == (lhs: SendableValue, rhs: SendableValue) -> Bool {
        guard let l = lhs.box as (any Equatable)?, let r = rhs.box as (any Equatable)? else {
            return false
        }
        return String(describing: l) == String(describing: r)
    }

    var boxedForInspection: Any { box }
}
