/// A type-erased sendable value for context properties.
public struct SendableValue: @unchecked Sendable, Equatable {
    private let box: any Sendable & Equatable

    /// Equality, captured at construction while the concrete type is still known.
    ///
    /// The obvious implementation — open both existentials and call a generic `compare` — is
    /// prohibited on Embedded Swift, which does not allow an existential to call an unbounded
    /// generic function. Capturing the comparison in a closure at `init` sidesteps that: `T` is
    /// concrete here, so the cast inside is a cast *to a concrete type*, which Embedded permits
    /// (unlike `as? any P`, which it does not).
    ///
    /// This is the same shape as `CompositionalInit`'s `PartialProperty` — a generic initialiser
    /// captures the type into a closure so the surrounding type need not be generic.
    private let _isEqual: @Sendable (any Sendable & Equatable) -> Bool

    public init<T: Sendable & Equatable>(_ value: T) {
        self.box = value
        self._isEqual = { other in
            guard let other = other as? T else { return false }
            return other == value
        }
    }

    public func get<T: Sendable & Equatable>(_ type: T.Type = T.self) -> T? {
        box as? T
    }

    /// Values of different concrete types are never equal.
    ///
    /// Note this replaced an earlier `String(describing:) == String(describing:)` comparison, which
    /// relied on reflection and was wrong on any platform for two distinct types that happen to
    /// render identically.
    public static func == (lhs: SendableValue, rhs: SendableValue) -> Bool {
        lhs._isEqual(rhs.box)
    }

    var boxedForInspection: Any { box }
}
