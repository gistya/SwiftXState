import Foundation

/// A logic whose snapshot can be persisted and restored — the capability behind `Actor`'s
/// `getPersistedSnapshot()` / `start(from:)`. `MachineLogic` conforms **only when its `Context` is
/// `Codable`** (conditional conformance), mirroring `Actor`'s `where Context: Codable` constraint.
public protocol PersistableLogic: ActorLogic {
    /// Serialize a snapshot (plus already-collected child snapshots) into a `PersistedSnapshot`.
    func persistedSnapshot(
        _ snapshot: Snapshot,
        children: [String: PersistedChildSnapshot]
    ) throws -> PersistedSnapshot

    /// Rebuild a snapshot from a persisted one (children are re-spawned separately).
    func restoredSnapshot(from persisted: PersistedSnapshot) throws -> Snapshot

    /// Re-spawn the children implied by a restored snapshot (`invoke` children + `spawnChild` entry
    /// actions), seeding each with its persisted state via the host, and return the synced snapshot.
    func restoreChildren<H: MachineHost>(_ snapshot: Snapshot, host: isolated H) async -> Snapshot
}

extension MachineLogic: PersistableLogic where Context: Codable {
    public func persistedSnapshot(
        _ snapshot: MachineSnapshot<Context>,
        children: [String: PersistedChildSnapshot]
    ) throws -> PersistedSnapshot {
        try SwiftXState.getPersistedSnapshot(from: snapshot, children: children)
    }

    public func restoredSnapshot(from persisted: PersistedSnapshot) throws -> MachineSnapshot<Context> {
        try restoreSnapshot(machine: machine, persisted: persisted, context: contextOverride)
    }
}
