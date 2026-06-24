import Foundation

/// Owns an actor's invoked/spawned child references and the set of ids that have been stopped.
/// Extracted from `Actor` so the same child bookkeeping can back any actor runtime (the generics
/// refactor's `StateActor`). The spawn/stop *orchestration* — creating child refs, registering
/// with the `ActorSystem`, inspection, and `_snapshot` sync — stays on the owning actor; this type
/// is just the container and its stopped-id tracking.
///
/// Accessed only under the owning actor's isolation, so it needs no lock.
final class ChildRegistry {
    private var children: [String: any ChildActorRef] = [:]
    private var stoppedIDs: Set<String> = []

    /// All live child refs, keyed by id.
    var all: [String: any ChildActorRef] { children }

    func get(_ id: String) -> (any ChildActorRef)? { children[id] }
    func contains(_ id: String) -> Bool { children[id] != nil }
    func add(_ id: String, _ child: any ChildActorRef) { children[id] = child }
    @discardableResult func remove(_ id: String) -> (any ChildActorRef)? { children.removeValue(forKey: id) }
    func removeAll() { children.removeAll() }

    func markStopped(_ id: String) { stoppedIDs.insert(id) }
    func markAllStopped() { stoppedIDs.formUnion(children.keys) }
    func wasStopped(_ id: String) -> Bool { stoppedIDs.contains(id) }

    /// Drops stopped-ids that are live again (mirrors `stoppedChildIDs.subtract(children.keys)`).
    func reconcileStopped() { stoppedIDs.subtract(children.keys) }

    /// A status snapshot of each live child, keyed by id (mirrors the old `children.mapValues`).
    func snapshots() -> [String: ChildActorSnapshot] {
        children.mapValues {
            ChildActorSnapshot(id: $0.id, status: $0.status, value: $0.snapshotValue, error: $0.errorMessage)
        }
    }
}
