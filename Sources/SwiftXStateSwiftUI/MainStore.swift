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
/// machines and a dashboard can read a uniform status/value without knowing each machine's `StateID`.
@MainActor
public protocol AnyMachineStore: AnyObject {
    /// A human-readable lifecycle status (`"active"`, `"done"`, …).
    var statusDescription: String { get }
    /// The active configuration rendered as a dotted/parallel path, or `nil` before the first snapshot.
    var configurationDescription: String? { get }
}

public extension MachineStore {
    var statusDescription: String { String(describing: status) }
    var configurationDescription: String? { configuration?.description }
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
/// ```swift
/// let store = MainStore()
/// let light  = store.track(TrafficLight(), id: "light")
/// let player = store.track(AudioPlayer(),  id: "player")
/// // …in a view: store.store("light", as: TrafficLight.self)?.matches(.green)
/// ```
@MainActor
@Observable
public final class MainStore {
    /// The tracked machine stores, keyed by id. Looked up (not observed) — membership changes are
    /// observed through `ids`, and each store is independently `@Observable`.
    @ObservationIgnored public private(set) var stores: [AnyHashable: any AnyMachineStore] = [:]

    /// The ids of the currently tracked machines, in track order — observe this for membership.
    public private(set) var ids: [AnyHashable] = []

    public init() {}

    /// Track a machine declaration: build its `MachineStore`, register it under `id`, and return the
    /// typed store (already self-starting).
    @discardableResult
    public func track<M: StateMachine>(_ machine: M, id: AnyHashable = UUID()) -> MachineStore<M> {
        register(MachineStore(machine), id: id)
    }

    /// Track an already-built `MachineStore`.
    @discardableResult
    public func track<M: StateMachine>(_ store: MachineStore<M>, id: AnyHashable = UUID()) -> MachineStore<M> {
        register(store, id: id)
    }

    private func register<M: StateMachine>(_ store: MachineStore<M>, id: AnyHashable) -> MachineStore<M> {
        stores[id] = store
        if !ids.contains(id) { ids.append(id) }
        return store
    }

    /// The typed store for `id`, if it is tracked and of type `M`.
    public func store<M: StateMachine>(_ id: AnyHashable, as _: M.Type = M.self) -> MachineStore<M>? {
        stores[id] as? MachineStore<M>
    }

    /// The erased store for `id` (uniform status/value, any machine type).
    public func anyStore(_ id: AnyHashable) -> (any AnyMachineStore)? { stores[id] }

    /// Stop tracking `id` (the underlying actor is released and its subscription cancelled on deinit).
    public func untrack(_ id: AnyHashable) {
        stores.removeValue(forKey: id)
        ids.removeAll { $0 == id }
    }
}
#endif
