import Foundation

/// A compile-time brand for a machine state, mapped to an XState-style dot path.
public protocol StateID: Sendable {
    /// Dot-separated path used by `MachineSnapshot.matches(_:)`.
    var statePath: String { get }
}

extension StateID where Self: RawRepresentable, Self.RawValue == String {
    public var statePath: String { rawValue }
}

/// Phantom-branded view over `MachineSnapshot` for type-state ergonomics.
///
/// The `Brand` type parameter documents the expected state family at API boundaries.
/// Runtime state is still `MachineSnapshot`; use `matches` / `is` / `narrowed` to test it.
public struct TypedSnapshot<Context: Sendable, Brand: StateID>: Sendable {
    public let raw: MachineSnapshot<Context>

    public init(_ raw: MachineSnapshot<Context>) {
        self.raw = raw
    }

    public var context: Context { raw.context }
    public var value: StateValue { raw.value }
    public var tags: Set<String> { raw.tags }
    public var status: SnapshotStatus { raw.status }
    public var children: [String: ChildActorSnapshot] { raw.children }

    public func getMeta() -> [String: [String: SendableValue]] {
        raw.getMeta()
    }

    public func matches(_ state: some StateID) -> Bool {
        raw.matches(state.statePath)
    }

    public func inState(_ state: Brand) -> Bool {
        raw.matches(state.statePath)
    }

    public func narrowed(to state: Brand) -> TypedSnapshot<Context, Brand>? {
        inState(state) ? self : nil
    }

    public func can(_ event: any Eventable) -> Bool {
        raw.can(event)
    }
}

/// Phantom-branded wrapper around `Actor` sharing the same state brand as `TypedSnapshot`.
public struct TypedActor<Context: Sendable, Brand: StateID>: Sendable {
    public let actor: Actor<Context>

    public init(_ actor: Actor<Context>) {
        self.actor = actor
    }

    public var snapshot: TypedSnapshot<Context, Brand> {
        TypedSnapshot(actor.snapshot)
    }

    @discardableResult
    public func start(context: Context? = nil) -> TypedSnapshot<Context, Brand> {
        actor.start(context: context)
        return snapshot
    }

    @discardableResult
    public func send(_ event: any Eventable) -> TypedSnapshot<Context, Brand> {
        actor.send(event)
        return snapshot
    }
}

public extension MachineSnapshot {
    func typed<Brand: StateID>(as _: Brand.Type = Brand.self) -> TypedSnapshot<Context, Brand> {
        TypedSnapshot(self)
    }

    func matches(_ state: some StateID) -> Bool {
        matches(state.statePath)
    }
}

public extension Actor {
    func typed<Brand: StateID>(as _: Brand.Type = Brand.self) -> TypedActor<Context, Brand> {
        TypedActor(self)
    }
}

public extension StateValue {
    func matches(_ state: some StateID) -> Bool {
        matches(state.statePath)
    }
}