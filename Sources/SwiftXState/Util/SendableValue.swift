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
        areEqual(lhs.box, rhs.box)
    }

    var boxedForInspection: Any { box }
}

/// Compares two type-erased `Equatable` values using their own `==`, by opening the existential and
/// casting the right-hand side to the left's concrete type. Distinct types are never equal.
///
/// This replaces an earlier `String(describing:) == String(describing:)` comparison. That version
/// relied on reflection (unavailable on Embedded Swift, where it would have degraded to a constant
/// placeholder and made *every* value compare equal), and it was already wrong on any platform for
/// two distinct types that happen to render identically.
private func areEqual(_ lhs: any Equatable, _ rhs: any Equatable) -> Bool {
    func compare<T: Equatable>(_ typed: T) -> Bool {
        guard let other = rhs as? T else { return false }
        return typed == other
    }
    return compare(lhs)
}
