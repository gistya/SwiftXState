#if SWIFTXSTATE_APPLE_SWIFTDATA
import Foundation
import SwiftData
import SwiftXState

/// Persists and restores actor snapshots using SwiftData.
public struct ActorPersistenceStore {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Saves the actor's current snapshot under a stable key (upserts).
    public func save<Context: Codable & Sendable>(
        _ actor: Actor<Context>,
        key: String
    ) throws {
        let persisted = try actor.getPersistedSnapshot()
        let data = try persisted.encodeJSON()

        var descriptor = FetchDescriptor<ActorSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.machineId = persisted.machineId
            existing.snapshotData = data
            existing.updatedAt = .now
        } else {
            modelContext.insert(
                ActorSnapshotRecord(
                    key: key,
                    machineId: persisted.machineId,
                    snapshotData: data
                )
            )
        }

        try modelContext.save()
    }

    /// Loads a persisted snapshot for the given key.
    public func load(key: String) throws -> PersistedSnapshot? {
        var descriptor = FetchDescriptor<ActorSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            return nil
        }
        return try PersistedSnapshot.decodeJSON(record.snapshotData)
    }

    /// Deletes a persisted snapshot for the given key.
    public func delete(key: String) throws {
        var descriptor = FetchDescriptor<ActorSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    /// Restores an actor from a persisted snapshot stored under `key`.
    @discardableResult
    public func restore<Context: Codable & Sendable>(
        _ actor: Actor<Context>,
        key: String,
        context: Context? = nil
    ) throws -> Bool {
        guard let persisted = try load(key: key) else {
            return false
        }
        actor.start(from: persisted, context: context)
        return true
    }

    /// Creates and hydrates an actor from a persisted snapshot stored under `key`.
    public func createActor<Context: Codable & Sendable>(
        _ machine: StateMachine<Context>,
        key: String,
        id: String? = nil,
        options: ActorOptions = ActorOptions(),
        context: Context? = nil
    ) throws -> Actor<Context>? {
        guard let persisted = try load(key: key) else {
            return nil
        }
        return SwiftXState.createActor(
            machine,
            snapshot: persisted,
            id: id,
            options: options,
            context: context
        )
    }
}

/// Convenience for registering SwiftXState persistence models in a `ModelContainer`.
public enum SwiftXStatePersistenceSchema {
    public static let modelTypes: [any PersistentModel.Type] = [
        ActorSnapshotRecord.self,
        ReplaySessionRecord.self,
    ]
}
#endif