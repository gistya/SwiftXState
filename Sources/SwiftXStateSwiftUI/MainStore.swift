#if SWIFTXSTATE_APPLE_UI
import Observation
import SwiftXState

/// Weak, `@unchecked Sendable` handle so the off-main subscription closure can reach back to the
/// main-actor store without capturing `self` across the `@Sendable` boundary (mirrors `MachineDriver`).
private final class WeakStoreBox<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?
    init(_ object: Object) { self.object = object }
}

// MARK: - MachineStore (one typed actor, observable on the main actor)

/// A `@MainActor`, `@Observable` projection of a single typed `MachineActor<M>` — the Plan-D-typed
/// counterpart of `MachineDriver`. It owns the actor, subscribes to its snapshot stream, and hops
/// every update onto the main actor so SwiftUI / `@Observable` view models can read it synchronously:
/// `configuration` (typed `Configuration<StateID>`), `context`, and `status`. Drive it with the typed
/// `send(_ id: EventID)`.
///
/// The actor lives off the main actor (it's a Swift `actor`); this store is the membrane that keeps
/// its updates collated on main, so multiple actors can update concurrently yet present a coherent,
/// glitch-free view.
@MainActor
@Observable
public final class MachineStore<M: StateMachine>: AnyMachineStore {
    /// The underlying typed actor — drop to it for `await`-style reads, persistence, or inspection.
    public let actor: MachineActor<M>

    /// The current active configuration, projected typed. `nil` only until the first snapshot lands.
    public private(set) var configuration: Configuration<M.StateID>?
    /// The current context.
    public private(set) var context: M.Context
    /// Lifecycle status: `.active` / `.done` / `.error` / `.stopped`.
    public private(set) var status: SnapshotStatus = .active

    @ObservationIgnored private var subscription: Subscription?

    /// Build a store from a machine declaration. The actor is started and subscribed asynchronously;
    /// `configuration` is `nil` and `context` is the declared initial context until the first
    /// snapshot arrives (typically the same tick).
    public init(_ machine: M) {
        self.actor = createActor(machine)
        self.context = machine.context
        self.configuration = nil
        start()
    }

    /// Build a store around an already-created actor (e.g. one spawned with inspection wired up).
    public init(actor: MachineActor<M>, initialContext: M.Context) {
        self.actor = actor
        self.context = initialContext
        self.configuration = nil
        start()
    }

    private func start() {
        let actor = self.actor
        let box = WeakStoreBox(self)
        Task { [box, actor] in
            let initial = await actor.start()
            let context = await actor.context
            let status = await actor.status
            await MainActor.run { [box] in
                box.object?.configuration = initial
                box.object?.context = context
                box.object?.status = status
            }
            let subscription = await actor.subscribe { configuration, context in
                Task { @MainActor [box] in
                    box.object?.configuration = configuration
                    box.object?.context = context
                }
            }
            await MainActor.run { [box] in box.object?.subscription = subscription }
        }
    }

    /// Send a typed event. The store updates once the actor processes it (and again via the
    /// subscription for any follow-on effects).
    public func send(_ id: M.EventID) {
        let actor = self.actor
        let box = WeakStoreBox(self)
        Task { [box, actor] in
            let configuration = await actor.send(id)
            let context = await actor.context
            let status = await actor.status
            await MainActor.run { [box] in
                box.object?.configuration = configuration
                box.object?.context = context
                box.object?.status = status
            }
        }
    }

    /// Whether the atomic state `id` is currently active.
    public func matches(_ id: M.StateID) -> Bool { configuration?.matches(id) ?? false }

    /// Whether a dotted path of state names is active (for nested compound/parallel states).
    public func matches(path: String) -> Bool { configuration?.matches(path: path) ?? false }

    deinit { subscription?.cancel() }
}

// MARK: - Erased view (for the collator / dashboards)

/// The type-erased face of a `MachineStore`, so a `MainStore` can hold a heterogeneous set of typed
/// machines and a dashboard can read a uniform identity/status/value without knowing each machine's
/// `StateID`.
@MainActor
public protocol AnyMachineStore: AnyObject {
    /// The actor's engine-assigned session id — a stable, unique identity for `ForEach` etc. (not a
    /// user-invented string).
    var id: String { get }
    /// The machine type's name, for display (`"TrafficLight"`).
    var typeName: String { get }
    /// A human-readable lifecycle status (`"active"`, `"done"`, …).
    var statusDescription: String { get }
    /// The active configuration rendered as a dotted/parallel path, or `nil` before the first snapshot.
    var configurationDescription: String? { get }
}

public extension MachineStore {
    var id: String { actor.id }
    var typeName: String { String(describing: M.self) }
    var statusDescription: String { String(describing: status) }
    var configurationDescription: String? { configuration?.description }
}

/// A **phantom-typed** key for tracking more than one machine of the same type in a `MainStore`
/// (e.g. two `TrafficLight`s). Because it carries `M`, lookups stay typed and cast-free. Define keys
/// as constants so call sites read `.north`, never a raw string:
///
/// ```swift
/// extension MachineKey where M == TrafficLight {
///     static var north: Self { .init("north") }
///     static var south: Self { .init("south") }
/// }
/// store.track(TrafficLight(), key: .north)
/// store.store(.north)?.matches(.green)
/// ```
public struct MachineKey<M: StateMachine>: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

// MARK: - MainStore (collate any number of actors on the main actor)

/// A `@MainActor`, `@Observable` store that subscribes to and **collates** the snapshots of any number
/// of typed actors, keeping all their updates together on the main actor. Bind it directly to UI or a
/// view model: read `ids` for the live set, fetch a typed `store(_:as:)` for one machine, or iterate
/// the erased `AnyMachineStore` faces for a dashboard.
///
/// This is the main-actor membrane over the many-Swift-actor world: each tracked machine runs on its
/// own actor, yet their state lands here coherently, glitch-free, ready to render.
///
/// Identity is **typed, not stringly**: track returns the store (hold it), or look one up by its
/// machine *type* — and, for several machines of one type, by a phantom-typed `MachineKey`.
///
/// ```swift
/// let store = MainStore()
/// let light  = store.track(TrafficLight())     // hold the returned typed store…
/// store.track(AudioPlayer())
/// store.store(TrafficLight.self)?.matches(.green)   // …or look it up by type — no string, no cast
///
/// store.track(TrafficLight(), key: .north)          // two of one type → typed keys
/// store.store(.north)?.matches(.green)
/// ```
@MainActor
@Observable
public final class MainStore {
    /// Internal storage key: the machine type, plus an optional `MachineKey` name for same-type
    /// multiples. No user-facing strings.
    private struct StoreID: Hashable {
        let type: ObjectIdentifier
        let name: String?
    }

    private var entries: [StoreID: any AnyMachineStore] = [:]

    public init() {}

    /// Track a machine declaration: build + start its `MachineStore`, register it (keyed by type, or
    /// by `key` for same-type multiples), and return the typed store — your primary handle.
    @discardableResult
    public func track<M: StateMachine>(_ machine: M, key: MachineKey<M>? = nil) -> MachineStore<M> {
        register(MachineStore(machine), key: key)
    }

    /// Track an already-built `MachineStore`.
    @discardableResult
    public func track<M: StateMachine>(_ store: MachineStore<M>, key: MachineKey<M>? = nil) -> MachineStore<M> {
        register(store, key: key)
    }

    private func register<M: StateMachine>(_ store: MachineStore<M>, key: MachineKey<M>?) -> MachineStore<M> {
        entries[StoreID(type: ObjectIdentifier(M.self), name: key?.name)] = store
        return store
    }

    /// The typed store for machine type `M` — `store(TrafficLight.self)`. Stringless, cast-free.
    public func store<M: StateMachine>(_ type: M.Type = M.self) -> MachineStore<M>? {
        entries[StoreID(type: ObjectIdentifier(M.self), name: nil)] as? MachineStore<M>
    }

    /// The typed store for a phantom-typed `key` (same-type multiples) — `store(.north)`.
    public func store<M: StateMachine>(_ key: MachineKey<M>) -> MachineStore<M>? {
        entries[StoreID(type: ObjectIdentifier(M.self), name: key.name)] as? MachineStore<M>
    }

    /// Every tracked store, erased — for dashboards. `ForEach` over them with `\.id` (the engine
    /// session id).
    public var all: [any AnyMachineStore] {
        Array(entries.values).sorted { $0.id < $1.id }
    }

    /// How many machines are tracked.
    public var count: Int { entries.count }

    /// Stop tracking machine type `M`.
    public func untrack<M: StateMachine>(_ type: M.Type = M.self) {
        entries[StoreID(type: ObjectIdentifier(M.self), name: nil)] = nil
    }

    /// Stop tracking the machine at `key`.
    public func untrack<M: StateMachine>(_ key: MachineKey<M>) {
        entries[StoreID(type: ObjectIdentifier(M.self), name: key.name)] = nil
    }
}
#endif
