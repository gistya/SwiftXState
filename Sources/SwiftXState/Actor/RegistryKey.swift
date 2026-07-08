/// A **typed** registry key for an `ActorSystem`: a `String` name that carries the target actor's
/// logic type `L` as a phantom, so `system.actor(key)` hands back a typed `Actor<L>`.
///
/// This is the Swift stand-in for XState v6's string-literal registry keys, which double as types.
/// Swift's `String` isn't a type, so the type rides on the key struct instead — but the outcome is
/// the same: a string identifies the actor at runtime, the type shapes the result at compile time.
/// Two keys may share the same `L` (e.g. many actors run the same machine); the **name** is the
/// identity, the type is only the overlay — so this never tries to key on the type itself.
///
/// ```swift
/// let logger = RegistryKey<MachineLogic<LogContext>>("logger")
/// system.set(logger, actor: loggerActor)
/// let ref = system.actor(logger)      // -> Actor<MachineLogic<LogContext>>?
/// ```
public struct RegistryKey<L: ActorLogic>: Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

public extension ActorSystem {
    /// Register `actor` under the typed `key` — its `name` becomes the system id, so the untyped
    /// `get(systemId:)` sees it too.
    func set<L>(_ key: RegistryKey<L>, actor: Actor<L>) {
        set(systemId: key.name, actor: actor)
    }

    /// The typed actor registered under `key`, or `nil` if none is registered under that name (or it
    /// isn't an `Actor<L>`). Resolves both directly-registered actors and spawned/invoked children
    /// (which are stored wrapped in a `ChildActorBox<L>`).
    func actor<L>(_ key: RegistryKey<L>) -> Actor<L>? {
        switch get(systemId: key.name) {
        case let actor as Actor<L>: return actor
        case let box as ChildActorBox<L>: return box.actor
        default: return nil
        }
    }
}
