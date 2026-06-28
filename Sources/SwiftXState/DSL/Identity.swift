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
    /// Default: the case name (e.g. `Light.State.red` → `"red"`). Override for custom wire names.
    var name: String { String(describing: self) }
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

// MARK: - String instantiation (the untyped escape hatch)

/// `String` as a (deliberately unsafe) identifier — this is what makes the string DSL just the
/// `StateID == String` / `EventID == String` instantiation of the one typed core. You lose
/// state-vs-event distinction and typo-checking; that's the point of the escape hatch.
extension String: @retroactive PropertyInitializable {
    public static var _blank: String { "" }
}

extension String: StateIdentifying, EventIdentifying {
    public var name: String { self }
}
