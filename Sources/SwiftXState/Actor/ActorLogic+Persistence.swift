import Foundation

/// A logic whose snapshot can be persisted and restored — the capability behind `LogicActor`'s
/// `getPersistedSnapshot()` / `start(from:)`. `MachineLogic` conforms **only when its `Context` is
/// `Codable`** (conditional conformance), mirroring `Actor`'s `where Context: Codable` constraint.
protocol PersistableLogic: ActorLogic {
    /// Serialize a snapshot (plus already-collected child snapshots) into a `PersistedSnapshot`.
    func persistedSnapshot(
        _ snapshot: Snapshot,
        children: [String: PersistedChildSnapshot]
    ) throws -> PersistedSnapshot
}

extension MachineLogic: PersistableLogic where Context: Codable {
    func persistedSnapshot(
        _ snapshot: MachineSnapshot<Context>,
        children: [String: PersistedChildSnapshot]
    ) throws -> PersistedSnapshot {
        try SwiftXState.getPersistedSnapshot(from: snapshot, children: children)
    }
}
