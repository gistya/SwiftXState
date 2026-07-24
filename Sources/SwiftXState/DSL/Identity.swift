import CompositionalInit

// MARK: - Identity

/// The base for a compile-time identifier (a state id or an event id). `Hashable` + `Sendable` so it
/// can key the schema and cross actor isolation; `PropertyInitializable` for the DSL's blank/clone
/// machinery. `name` is the lowered `String` form — used for the engine's node/event keys, dotted
/// state paths, serialization, and inspection. Strings live *only* at that lowering boundary; the
/// authoring and matching surface stays typed.
public protocol BasicIdentifying: Hashable, Sendable, PropertyInitializable {
    /// The lowered string form (engine keys / paths / JSON / inspection).
    var name: String { get }
}

public extension BasicIdentifying {
    /// Default: the case *discriminant* (e.g. `Light.State.red` → `"red"`, and crucially
    /// `Event.increment(by: 5)` → `"increment"`, not `"increment(by: 5)"`). Using `Mirror` to read the
    /// enum label keeps the routing key stable across an event's payload. Override for custom wire names.
    ///
    /// Unavailable on Embedded Swift, which has no `Mirror`. Give the identifier a `String` raw
    /// value and the `RawRepresentable` overload below supplies `name` for free — that covers the
    /// common case:
    ///
    /// ```swift
    /// enum State: String, StateIdentifying { case red, green }
    /// ```
    ///
    /// Identifiers carrying associated values must declare `name` themselves. As with
    /// ``StateEvent/eventType``, a compile error by design rather than a degraded default: `name` is
    /// the engine's node/event key, so a placeholder would misroute rather than fail.
    #if !hasFeature(Embedded)
    var name: String {
        let mirror = Mirror(reflecting: self)
        if mirror.displayStyle == .enum, let label = mirror.children.first?.label {
            return label
        }
        return String(describing: self)
    }
    #endif
}

public extension BasicIdentifying where Self: RawRepresentable, Self.RawValue == String {
    var name: String { rawValue }
}

/// A compile-time state identifier — declare one `case` per state.
public protocol StateIdentifying: BasicIdentifying {}

/// A compile-time event identifier — declare one `case` per event kind.
public protocol EventIdentifying: BasicIdentifying {}

// MARK: - Identity associations

/// A type that names its state-id family.
public protocol StateIdentifiable {
    associatedtype StateID: StateIdentifying
}

/// A type that names its event-id family.
public protocol EventIdentifiable {
    associatedtype EventID: EventIdentifying
}

/// A type that carries a `Context`.
public protocol Contextual {
    associatedtype Context: Sendable
}

/// The full schema identity: a context, an event-id family, and a state-id family. This is the
/// common surface every machine component (`SchemaReducible`, `ResolvedMachine`, `MachineSchema`) shares.
public protocol MachineSchemable: Contextual, EventIdentifiable, StateIdentifiable {}

extension String: @retroactive PropertyInitializable {}
extension String: @retroactive Cloneable {}

extension String: StateIdentifying, EventIdentifying {
    public var name: String { self }
}
