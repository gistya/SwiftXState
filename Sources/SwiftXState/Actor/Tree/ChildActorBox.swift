import Synchronization

/// A `ChildActorRepresentable` adapter wrapping the generic `Actor` — XState's "an `ActorRef` wraps the
/// interpreter". One generic adapter replaces the per-kind `*ChildRef` classes: the parent talks to
/// it through `ChildActorRepresentable` while the real work runs in `Actor<L>`.
///
/// The pieces that vary by kind are injected:
///   - `startAction` — how `start()` boots the inner actor (`start(input:)` for runnable children;
///     `start(from:)` for a restored machine child).
///   - `persistAction` — how a persisted child snapshot is produced (`.opaque(status)` for runnable
///     children; `.machine(...)` for a Codable machine child).
///   - `machineId` / `definitionJSON` — surfaced for machine children, nil otherwise.
/// Runnable children use the convenience init, which supplies the `start(input:)` + opaque-persist
/// defaults, so their call sites stay unchanged.
final class ChildActorBox<L: ActorLogic>: ChildActorRepresentable, @unchecked Sendable {
    /// The wrapped engine. Internal (not private) so `@testable` tests can inspect a machine child's
    /// live snapshot / nested children after restore.
    let actor: Actor<L>
    let id: String
    let systemId: String?
    private let inspectableValue: Bool
    let machineId: String?
    let definitionJSON: String?
    private let startAction: @Sendable (Actor<L>) async -> Void
    private let persistAction: @Sendable (Actor<L>, SnapshotStatus, String?) async throws -> PersistedChildSnapshot?

    private let lock = Mutex(false)
    private var cachedStatus: SnapshotStatus = .stopped
    private var cachedError: String?
    private var statusSubscription: Subscription?

    var status: SnapshotStatus { lock.withLock { _ in cachedStatus } }
    var errorMessage: String? { lock.withLock { _ in cachedError } }
    var inspectable: Bool { inspectableValue }

    init(
        actor: Actor<L>,
        id: String,
        systemId: String?,
        inspectable: Bool,
        machineId: String?,
        definitionJSON: String?,
        start: @escaping @Sendable (Actor<L>) async -> Void,
        persist: @escaping @Sendable (Actor<L>, SnapshotStatus, String?) async throws -> PersistedChildSnapshot?
    ) {
        self.actor = actor
        self.id = id
        self.systemId = systemId
        self.inspectableValue = inspectable
        self.machineId = machineId
        self.definitionJSON = definitionJSON
        self.startAction = start
        self.persistAction = persist
    }

    /// Runnable children (callback / task / observable / transition / store): `start(input:)`, and an
    /// opaque persisted snapshot (status + error).
    convenience init(
        actor: Actor<L>,
        id: String,
        systemId: String?,
        input: SendableValue?,
        inspectable: Bool
    ) {
        self.init(
            actor: actor,
            id: id,
            systemId: systemId,
            inspectable: inspectable,
            machineId: nil,
            definitionJSON: nil,
            start: { inner in await inner.start(input: input) },
            persist: { _, status, error in .opaque(PersistedOpaqueChildSnapshot(status: status, error: error)) }
        )
    }

    func start() async {
        // Subscribe before start so a fast-completing child's terminal status isn't missed.
        statusSubscription = await actor.subscribeStatus { [weak self] status, error in
            guard let self else { return }
            lock.withLock { _ in cachedStatus = status; cachedError = error }
        }
        await startAction(actor)
    }

    func stop() async {
        statusSubscription?.cancel()
        statusSubscription = nil
        await actor.stop()
        lock.withLock { _ in cachedStatus = .stopped }
    }

    func send(_ event: any Eventable) async {
        await actor.send(event)
    }

    func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) async -> Subscription {
        await actor.on(eventType, handler: handler)
    }

    func subscribe(_ handler: @escaping @Sendable (ChildActorSnapshot) -> Void) async -> Subscription {
        await actor.subscribeChildSnapshot(id: id, handler)
    }
}

extension ChildActorBox: PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot? {
        guard status != .stopped else { return nil }
        return try await persistAction(actor, status, errorMessage)
    }
}
